-- =============================================================================
-- Etapa 3 — Sugestão de motorista para descontos (29/10/2026). Aprovado pelo Jefferson em 29/10/2026.
-- Fonte viva: checklist de Retirada (quem retirou o carro e ainda não tinha devolvido no horário).
-- Telemetria Questar: lógica pronta, DESLIGADA por padrão (não há identificação de motorista nos carros hoje).
-- A sugestão vai só para motorista_sugerido_id; o motorista cobrado (motorista_id) só é preenchido por uma pessoa.
-- Retorno sem dado pessoal: id, nome, matrícula, origem, confiança e horários.
-- =============================================================================

-- ligação código de motorista da Questar → motorista (vazia até existir identificação nos carros)
alter table frota.motoristas add column questar_driver_code text;
create unique index motoristas_questar_driver_code on frota.motoristas (questar_driver_code) where questar_driver_code is not null;
comment on column frota.motoristas.questar_driver_code is 'Código do motorista na Questar (driver_code das viagens). Vazio enquanto os carros não tiverem identificação de motorista.';

create or replace function frota.sugerir_motorista(p_veiculo uuid, p_quando timestamptz, p_usar_telemetria boolean default false)
returns table (motorista_id uuid, nome text, matricula text, origem text, confianca text,
               retirada_em timestamptz, devolvida_em timestamptz, detalhe text)
language plpgsql stable security definer set search_path = frota, public as $$
begin
  if auth.uid() is not null and not (coalesce(meu_papel() = 'admin', false) or tenho_modulo('multas')) then
    raise exception 'Sem permissão: só admin ou quem opera Multas.';
  end if;
  if p_veiculo is null or p_quando is null then return; end if;

  -- 1. checklist de Retirada aberta no horário
  return query
  select m.id, m.nome, m.matricula, 'checklist'::text,
         case when c.fechada_como = 'painel' then 'media'
              when p_quando - c.enviado_em > interval '24 hours' then 'media'
              else 'alta' end,
         c.enviado_em, c.fechada_em,
         case when c.fechada_como = 'painel' then 'Retirada fechada pelo painel (sem devolução registrada)'
              when p_quando - c.enviado_em > interval '24 hours' then 'Retirada aberta havia mais de 24 h (devolução atrasada)'
              when c.fechada_em is null then 'Retirada ainda aberta'
              else 'Retirada e devolução cobrem o horário' end
    from checklists c
    join lateral (select mo.id, mo.nome, mo.matricula from motoristas mo
                  where mo.matricula = c.colaborador_matricula
                  order by mo.ativo desc, mo.nome limit 1) m on true
   where c.veiculo_id = p_veiculo and c.tipo = 'retirada' and c.status = 'enviado'
     and c.enviado_em <= p_quando and (c.fechada_em is null or c.fechada_em > p_quando)
   order by c.enviado_em desc;

  -- 2. telemetria (desligada por padrão): viagem que cobre o horário, com código ligado a um motorista
  if p_usar_telemetria then
    return query
    select m.id, m.nome, m.matricula, 'telemetria'::text, 'alta'::text, t.inicio, t.fim, 'Viagem da Questar cobre o horário'::text
      from telemetria_viagens t
      join motoristas m on m.questar_driver_code = nullif(trim(t.driver_code), '')
     where t.veiculo_id = p_veiculo and t.inicio <= p_quando and t.fim >= p_quando;
  end if;
end $$;
revoke execute on function frota.sugerir_motorista(uuid, timestamptz, boolean) from public, anon;
grant execute on function frota.sugerir_motorista(uuid, timestamptz, boolean) to authenticated, service_role;
comment on function frota.sugerir_motorista(uuid, timestamptz, boolean) is 'Quem estava com o carro no horário (checklist de Retirada; telemetria só com p_usar_telemetria). Só sugere — nunca confirma cobrança. Sem dado pessoal no retorno.';

-- na criação do desconto: preenche só a SUGESTÃO, e só quando há um único motorista apontado
-- (roda depois de descontos_folha_regras, que já completou veículo e horário pela multa)
create or replace function frota.tg_descontos_folha_sugestao() returns trigger
language plpgsql security definer set search_path = frota, public as $$
declare n int; mid uuid; org text;
begin
  if new.motorista_sugerido_id is null and new.pipefy_card_id is null and new.ocorrida_em is not null then
    select count(distinct s.motorista_id), min(s.motorista_id::text)::uuid, min(s.origem)
      into n, mid, org
      from frota.sugerir_motorista(new.veiculo_id, new.ocorrida_em) s;
    if n = 1 then
      new.motorista_sugerido_id := mid;
      new.origem_sugestao := org;
    end if;
  end if;
  return new;
end $$;
revoke execute on function frota.tg_descontos_folha_sugestao() from public, anon, authenticated;
create trigger descontos_folha_sugestao before insert on frota.descontos_folha
  for each row execute function frota.tg_descontos_folha_sugestao();
