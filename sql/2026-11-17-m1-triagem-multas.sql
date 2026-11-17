-- M1 (17/11/2026): Triagem de multas (pedido do Jefferson): e-mails de infração que chegam no frota@ vão para uma
-- fila própria em Multas (não para a triagem financeira), com o condutor sugerido pelo checklist de Retirada.
--
--  * multas_triagem: uma linha por e-mail; PDF no bucket privado multas-triagem ({id}/notificacao.pdf), guardado como
--    CAMINHO. Dados lidos do PDF/assunto (Regras.lerNotificacaoMulta na Edge Function): placa, data/hora, AIT, órgão,
--    código, valor — a tela deixa corrigir placa e data/hora.
--  * gatilho: acha o veículo pela placa (inclusive arquivado: multa chega depois da devolução) e sugere o condutor
--    pelo checklist de Retirada daquele carro aberto no horário (mesma regra de sugerir_motorista), guardando a
--    referência do checklist. Recalcula quando a placa ou a data/hora mudam.
--  * status pendente → registrada (com multa_id, criada pela tela de Multas) | descartada (motivo ≥ 5 letras);
--    quem/quando pelo login; só admin reabre.
--  * acesso: lê e decide só admin e quem OPERA Multas (tem nome de motorista); ninguém cria pela tela (só a Edge
--    Function, service_role) e ninguém apaga.

create table frota.multas_triagem (
  id uuid primary key default gen_random_uuid(),
  message_id text unique,
  origem text not null default 'email' check (origem in ('email', 'triagem_financeira')),
  remetente text, assunto text,
  data_recebimento timestamptz not null default now(),
  motivo_deteccao text,
  caminho_pdf text, outros_anexos int not null default 0,
  placa_lida text, veiculo_id uuid references frota.veiculos(id),
  data_infracao timestamptz, ait text, orgao text, codigo_infracao text, valor_lido numeric(12,2),
  sugestao_checklist_id uuid references frota.checklists(id),
  sugestao_motorista_id uuid references frota.motoristas(id),
  sugestao_nome text, sugestao_matricula text, sugestao_confianca text, sugestao_detalhe text,
  sugestao_retirada_em timestamptz, sugestao_devolvida_em timestamptz,
  status text not null default 'pendente' check (status in ('pendente', 'registrada', 'descartada')),
  multa_id uuid references frota.multas(id),
  motivo_descarte text,
  decidido_por uuid, decidido_por_nome text, decidido_em timestamptz,
  criado_em timestamptz not null default now()
);
create index multas_triagem_status on frota.multas_triagem (status, data_recebimento desc);
alter table frota.multas_triagem enable row level security;
create policy ver_multas_triagem on frota.multas_triagem for select to authenticated
  using (frota.meu_papel() = 'admin' or frota.tenho_modulo('multas'));
create policy decidir_multas_triagem on frota.multas_triagem for update to authenticated
  using (frota.meu_papel() = 'admin' or frota.tenho_modulo('multas'))
  with check (frota.meu_papel() = 'admin' or frota.tenho_modulo('multas'));
grant select, update on frota.multas_triagem to authenticated;
comment on table frota.multas_triagem is 'Fila de e-mails de infração (Triagem de multas). Criada só pela Edge Function inbound-triagem-nfs.';

-- condutor pela Retirada aberta no horário (mesma regra de sugerir_motorista), com a referência do checklist
create or replace function frota.multa_sugestao_checklist(p_veiculo uuid, p_quando timestamptz)
returns table (checklist_id uuid, motorista_id uuid, nome text, matricula text, confianca text, retirada_em timestamptz, devolvida_em timestamptz, detalhe text)
language sql stable security definer set search_path = frota, public as $$
  select c.id, m.id, m.nome, m.matricula,
         case when c.fechada_como = 'painel' then 'media' when p_quando - c.enviado_em > interval '24 hours' then 'media' else 'alta' end,
         c.enviado_em, c.fechada_em,
         case when c.fechada_como = 'painel' then 'Retirada fechada pelo painel (sem devolução registrada)'
              when p_quando - c.enviado_em > interval '24 hours' then 'Retirada aberta havia mais de 24 h (devolução atrasada)'
              when c.fechada_em is null then 'Retirada ainda aberta'
              else 'Retirada e devolução cobrem o horário' end
    from checklists c
    join lateral (select mo.id, mo.nome, mo.matricula from motoristas mo where mo.matricula = c.colaborador_matricula
                  order by mo.ativo desc, mo.nome limit 1) m on true
   where p_veiculo is not null and p_quando is not null
     and c.veiculo_id = p_veiculo and c.tipo = 'retirada' and c.status = 'enviado'
     and c.enviado_em <= p_quando and (c.fechada_em is null or c.fechada_em > p_quando)
   order by c.enviado_em desc limit 1;
$$;
revoke all on function frota.multa_sugestao_checklist(uuid, timestamptz) from public, anon, authenticated;

create or replace function frota.tg_multas_triagem() returns trigger
language plpgsql security definer set search_path = frota, public as $$
declare s record;
begin
  if tg_op = 'UPDATE' then
    if (new.message_id, new.remetente, new.assunto, new.data_recebimento, new.caminho_pdf, new.origem)
       is distinct from (old.message_id, old.remetente, old.assunto, old.data_recebimento, old.caminho_pdf, old.origem) then
      raise exception 'Os dados do e-mail recebido não podem ser alterados.';
    end if;
    if new.status is distinct from old.status then
      if old.status <> 'pendente' and meu_papel() is distinct from 'admin' then raise exception 'Só o admin reabre uma multa já triada.'; end if;
      if new.status = 'descartada' and length(btrim(coalesce(new.motivo_descarte, ''))) < 5 then raise exception 'Escreva o motivo do descarte (mínimo 5 letras).'; end if;
      if new.status = 'registrada' and new.multa_id is null then raise exception 'Registrada precisa da multa criada.'; end if;
      if new.status = 'pendente' then new.motivo_descarte := null; new.multa_id := null; new.decidido_por := null; new.decidido_por_nome := null; new.decidido_em := null;
      else new.decidido_por := auth.uid(); new.decidido_por_nome := nome_usuario_atual(); new.decidido_em := now(); end if;
      if new.status = 'registrada' then new.motivo_descarte := null; end if;
    end if;
  else
    new.status := 'pendente'; new.multa_id := null; new.decidido_por := null; new.decidido_por_nome := null; new.decidido_em := null;
  end if;
  new.placa_lida := nullif(upper(regexp_replace(coalesce(new.placa_lida, ''), '[^A-Za-z0-9]', '', 'g')), '');
  if tg_op = 'INSERT' or new.placa_lida is distinct from old.placa_lida then
    new.veiculo_id := (select v.id from veiculos v where v.placa = new.placa_lida);
  end if;
  if tg_op = 'INSERT' or new.veiculo_id is distinct from old.veiculo_id or new.data_infracao is distinct from old.data_infracao then
    select * into s from multa_sugestao_checklist(new.veiculo_id, new.data_infracao);
    new.sugestao_checklist_id := s.checklist_id; new.sugestao_motorista_id := s.motorista_id; new.sugestao_nome := s.nome;
    new.sugestao_matricula := s.matricula; new.sugestao_confianca := s.confianca; new.sugestao_detalhe := s.detalhe;
    new.sugestao_retirada_em := s.retirada_em; new.sugestao_devolvida_em := s.devolvida_em;
  end if;
  return new;
end $$;
revoke all on function frota.tg_multas_triagem() from public, anon, authenticated;
create trigger multas_triagem_regras before insert or update on frota.multas_triagem
  for each row execute function frota.tg_multas_triagem();

-- bucket privado do PDF da notificação
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('multas-triagem', 'multas-triagem', false, 10485760, array['application/pdf'])
on conflict (id) do nothing;
create policy "multas_triagem_ler" on storage.objects for select to authenticated
  using (bucket_id = 'multas-triagem' and (frota.meu_papel() = 'admin' or frota.tenho_modulo('multas')));
