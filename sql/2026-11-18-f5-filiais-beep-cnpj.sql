-- F5 (18/11/2026, pedido do Jefferson): CNPJ da Beep (tomadora/pagadora) por filial = hub.
-- Varredura feita em 18/11: nenhuma das 1.319 notas do banco guarda o CNPJ tomador (a planilha "Controle de NFS" só tem o
-- CNPJ do fornecedor/beneficiado e a importação do XML lê só o emitente). Os únicos documentos com o CNPJ da Beep são os PDFs
-- da triagem financeira: as 3 faturas da Versa Fuel de 17/11 (BEEP SERVICOS MEDICOS LTDA) — o hub vem do assunto do e-mail.
--   Barra Funda  → 28.286.170/0025-70 (NF e boleto; endereço Rua Eng. Stevenson, 30)
--   Tatuapé      → 28.286.170/0013-37 (NF e boleto; o boleto diz "VILA GOMES" — conferir)
--   Vila Olímpia → 28.286.170/0004-46 (NF e boleto; "VILA OLIMPIA")
-- Ficam "a conferir"; os outros 9 hubs são cadastrados na tela (Financeiro → Filiais da Beep).
-- Daqui em diante a Edge Function grava o CNPJ da Beep lido em cada NF/boleto (financeiro_notas_triagem.cnpj_tomador_lido).

create table frota.beep_filiais (
  hub_id uuid primary key references frota.hubs(id),
  cnpj text not null check (cnpj ~ '^\d{14}$'),
  razao_social text not null default 'BEEP SERVICOS MEDICOS LTDA',
  origem text not null default 'manual' check (origem in ('nf_pdf', 'manual')),
  evidencia text,
  conferido boolean not null default false,
  atualizado_por uuid, atualizado_por_nome text,
  atualizado_em timestamptz not null default now()
);
alter table frota.beep_filiais enable row level security;
create policy ver_beep_filiais on frota.beep_filiais for select to authenticated
  using (frota.meu_papel() = 'admin' or frota.posso_ver('financeiro') or frota.posso_ver('manutencao') or frota.posso_ver('frota'));
create policy gravar_beep_filiais on frota.beep_filiais for insert to authenticated
  with check (frota.meu_papel() = 'admin' or frota.tenho_modulo('financeiro'));
create policy editar_beep_filiais on frota.beep_filiais for update to authenticated
  using (frota.meu_papel() = 'admin' or frota.tenho_modulo('financeiro'))
  with check (frota.meu_papel() = 'admin' or frota.tenho_modulo('financeiro'));
grant select, insert, update on frota.beep_filiais to authenticated;
comment on table frota.beep_filiais is 'CNPJ da Beep (tomadora da NF) por filial = hub. Usado na resposta de orçamento e no resumo do Pipefy.';

create or replace function frota.tg_beep_filiais() returns trigger
language plpgsql set search_path = frota, public as $$
begin
  new.cnpj := regexp_replace(coalesce(new.cnpj, ''), '\D', '', 'g');
  if length(new.cnpj) <> 14 then raise exception 'CNPJ deve ter 14 dígitos.'; end if;
  if auth.uid() is not null then
    if tg_op = 'INSERT' or new.cnpj is distinct from old.cnpj then new.origem := 'manual'; new.evidencia := coalesce(nullif(btrim(new.evidencia), ''), 'cadastrado na tela'); end if;
    new.atualizado_por := auth.uid(); new.atualizado_por_nome := nome_usuario_atual();
  end if;
  new.atualizado_em := now();
  return new;
end $$;
revoke all on function frota.tg_beep_filiais() from public, anon, authenticated;
create trigger beep_filiais_regras before insert or update on frota.beep_filiais
  for each row execute function frota.tg_beep_filiais();

insert into frota.beep_filiais (hub_id, cnpj, origem, evidencia)
select h.id, x.cnpj, 'nf_pdf', x.evidencia
  from (values ('Barra Funda', '28286170002570', 'Fatura Versa Fuel 01–15/11/2026 (Barra Funda): NF e boleto, Rua Eng. Stevenson, 30'),
               ('Tatuapé', '28286170001337', 'Fatura Versa Fuel 01–15/11/2026 (Tatuapé): NF e boleto; o boleto diz "VILA GOMES" — conferir'),
               ('Vila Olímpia', '28286170000446', 'Fatura Versa Fuel 01–15/11/2026 (Vila Olímpia): NF e boleto, "VILA OLIMPIA"')) x(hub, cnpj, evidencia)
  join frota.hubs h on h.nome = x.hub;

alter table frota.financeiro_notas_triagem add column cnpj_tomador_lido text check (cnpj_tomador_lido is null or cnpj_tomador_lido ~ '^\d{14}$');
update frota.financeiro_notas_triagem set cnpj_tomador_lido = '28286170002570' where id = '5a158c01-1d05-4f4b-8002-ee5373caaf6e';
update frota.financeiro_notas_triagem set cnpj_tomador_lido = '28286170001337' where id = '1cd5ceeb-e7b8-4b7d-b186-e44b54f045de';
update frota.financeiro_notas_triagem set cnpj_tomador_lido = '28286170000446' where id = '196cf96e-cddf-4b2f-a975-f71ef08d646a';

do $$ begin
  if (select count(*) from frota.beep_filiais) <> 3 then raise exception 'esperava 3 filiais'; end if;
  if (select count(*) from frota.financeiro_notas_triagem where cnpj_tomador_lido is not null) <> 3 then raise exception 'esperava 3 notas com CNPJ'; end if;
end $$;
