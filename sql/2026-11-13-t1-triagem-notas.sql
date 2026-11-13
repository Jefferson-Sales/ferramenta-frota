-- T1 (13/11/2026): Triagem de notas que chegam por e-mail (caixa de entrada do Financeiro).
-- Decisões do Jefferson: reaproveitar `fornecedores` (só ganha status_homologacao — sem segundo cadastro);
-- teste só com dados simulados (nada fictício fica no banco).
--
-- Fluxo: e-mail → Edge Function inbound-triagem-nfs (service_role) grava a linha e os PDFs no bucket
-- privado notas-triagem → Financeiro lê na tela, confere e Aprova (futuro: cria a nota e envia ao Pipefy)
-- ou Reprova com justificativa (futuro: e-mail de volta ao fornecedor).
-- Guardamos o CAMINHO dos PDFs no bucket, nunca link: o link é assinado na hora, com o login de quem vê.

-- 1) Fornecedor homologado (mesmo cadastro das notas, do DRE e do Pipefy)
alter table frota.fornecedores
  add column if not exists status_homologacao text not null default 'pendente'
  constraint fornecedores_status_homologacao_valido check (status_homologacao in ('pendente', 'homologado', 'bloqueado'));

-- 2) Regra do prazo (= Regras.prazoTriagem): dias entre o recebimento (dia de Brasília) e o vencimento; em dia se >= 10
create or replace function frota.prazo_triagem(p_recebido timestamptz, p_vencimento date)
returns text language sql immutable set search_path = '' as $$
  select case
    when p_vencimento is null then 'sem_vencimento'
    when p_vencimento - (p_recebido at time zone 'America/Sao_Paulo')::date >= 10 then 'em_dia'
    else 'prazo_curto' end;
$$;

-- 3) Caixa de entrada
create table if not exists frota.financeiro_notas_triagem (
  id uuid primary key default gen_random_uuid(),
  message_id text unique,                        -- id do e-mail: o mesmo e-mail reenviado não duplica
  remetente text,
  assunto text,
  data_recebimento timestamptz not null default now(),
  cnpj_lido text constraint triagem_cnpj_formato check (cnpj_lido is null or cnpj_lido ~ '^\d{14}$'),
  numero_nota_lido text,
  valor_lido numeric(14,2) constraint triagem_valor_positivo check (valor_lido is null or valor_lido > 0),
  data_vencimento date,
  dias_ate_vencimento integer,                   -- gatilho
  status_validacao_dias text not null default 'sem_vencimento'
    constraint triagem_status_dias_valido check (status_validacao_dias in ('em_dia', 'prazo_curto', 'sem_vencimento')),
  fornecedor_id uuid references frota.fornecedores(id),
  caminho_pdf_nf text,                           -- caminho em notas-triagem ({id}/nf.pdf)
  caminho_pdf_boleto text,                       -- caminho em notas-triagem ({id}/boleto.pdf)
  outros_anexos integer not null default 0,
  status_aprovacao text not null default 'pendente'
    constraint triagem_status_aprovacao_valido check (status_aprovacao in ('pendente', 'aprovada', 'reprovada')),
  justificativa_reprovacao text,
  decidido_por uuid,
  decidido_por_nome text,
  decidido_em timestamptz,
  nota_fiscal_id uuid references frota.notas_fiscais(id),   -- futuro: nota criada ao aprovar
  created_at timestamptz not null default now()
);
create index if not exists triagem_status_idx on frota.financeiro_notas_triagem (status_aprovacao, data_recebimento desc);

-- 4) Gatilho: prazo, fornecedor pelo CNPJ, decisão carimbada pelo login
create or replace function frota.tg_triagem_notas()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.cnpj_lido := nullif(regexp_replace(coalesce(new.cnpj_lido, ''), '\D', '', 'g'), '');
    if new.fornecedor_id is null and new.cnpj_lido is not null then
      select f.id into new.fornecedor_id from frota.fornecedores f where f.cnpj = new.cnpj_lido;
    end if;
    new.status_aprovacao := 'pendente';
    new.justificativa_reprovacao := null; new.decidido_por := null; new.decidido_por_nome := null; new.decidido_em := null;
  else
    -- dados lidos do e-mail não mudam pela tela (só fornecedor, vencimento corrigido e a decisão)
    if new.message_id is distinct from old.message_id or new.remetente is distinct from old.remetente
       or new.data_recebimento is distinct from old.data_recebimento or new.caminho_pdf_nf is distinct from old.caminho_pdf_nf
       or new.caminho_pdf_boleto is distinct from old.caminho_pdf_boleto then
      raise exception 'Os dados do e-mail recebido não podem ser alterados.';
    end if;
    if new.status_aprovacao is distinct from old.status_aprovacao then
      if old.status_aprovacao <> 'pendente' and frota.meu_papel() is distinct from 'admin' then
        raise exception 'Só o admin reabre uma nota já decidida.';
      end if;
      if new.status_aprovacao = 'reprovada' and length(trim(coalesce(new.justificativa_reprovacao, ''))) < 10 then
        raise exception 'Escreva a justificativa da reprovação (mínimo 10 letras); ela vai para o fornecedor.';
      end if;
      if new.status_aprovacao = 'pendente' then
        new.justificativa_reprovacao := null; new.decidido_por := null; new.decidido_por_nome := null; new.decidido_em := null;
      else
        if new.status_aprovacao = 'aprovada' then new.justificativa_reprovacao := null; end if;
        new.justificativa_reprovacao := nullif(trim(new.justificativa_reprovacao), '');
        new.decidido_por := auth.uid(); new.decidido_por_nome := frota.nome_usuario_atual(); new.decidido_em := now();
      end if;
    elsif new.justificativa_reprovacao is distinct from old.justificativa_reprovacao
       or new.decidido_por is distinct from old.decidido_por or new.decidido_em is distinct from old.decidido_em then
      raise exception 'A decisão só muda junto com o status.';
    end if;
  end if;
  new.dias_ate_vencimento := new.data_vencimento - (new.data_recebimento at time zone 'America/Sao_Paulo')::date;
  new.status_validacao_dias := frota.prazo_triagem(new.data_recebimento, new.data_vencimento);
  return new;
end;
$$;
create trigger triagem_notas_regras before insert or update on frota.financeiro_notas_triagem
  for each row execute function frota.tg_triagem_notas();

-- 5) Acesso: fila de trabalho do Financeiro — admin e quem opera o Financeiro (o boleto tem dados bancários).
--    Quem grava é só a Edge Function (service_role). Ninguém apaga (não há policy de DELETE).
alter table frota.financeiro_notas_triagem enable row level security;
create policy triagem_ler on frota.financeiro_notas_triagem for select to authenticated
  using (frota.meu_papel() = 'admin' or frota.tenho_modulo('financeiro'));
create policy triagem_decidir on frota.financeiro_notas_triagem for update to authenticated
  using (frota.meu_papel() = 'admin' or frota.tenho_modulo('financeiro'))
  with check (frota.meu_papel() = 'admin' or frota.tenho_modulo('financeiro'));
grant select, update on frota.financeiro_notas_triagem to authenticated;
grant all on frota.financeiro_notas_triagem to service_role;

-- 6) Bucket privado dos PDFs (10 MB; PDF, imagem e XML da NF-e). Grava só a Edge Function (service_role).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('notas-triagem', 'notas-triagem', false, 10485760,
        array['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'application/xml', 'text/xml'])
on conflict (id) do nothing;
create policy notas_triagem_ler on storage.objects for select to authenticated
  using (bucket_id = 'notas-triagem' and (frota.meu_papel() = 'admin' or frota.tenho_modulo('financeiro')));
