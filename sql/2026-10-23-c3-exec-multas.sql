-- =============================================================================
-- C3: quadrante de Multas da Visão Executiva (23/10/2026)
--   exec_multas(p_ini, p_fim, p_hub) → um JSON:
--     período (pela data da infração, dia de Brasília): total, valor, por status, por hub,
--     motivos (texto antes do " | " da descrição; o agrupamento fica em Regras.classificarMotivo);
--     fila atual (sem período): aguardando retorno da liderança e quantas com alerta;
--     ultima_infracao (as notificações chegam com atraso).
-- security invoker (RLS de Multas). Dados de hoje: grau, pontos, código e motorista vazios
-- nas 459 multas — ranking de motoristas fica "Sem dados" até a etapa D2.
-- =============================================================================
create or replace function frota.exec_multas(p_ini date, p_fim date, p_hub uuid default null)
returns jsonb language plpgsql stable security invoker set search_path = frota as $$
declare
  ini_ts timestamptz := (p_ini::timestamp at time zone 'America/Sao_Paulo');
  fim_ts timestamptz := ((p_fim + 1)::timestamp at time zone 'America/Sao_Paulo');
  r jsonb;
begin
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Período inválido.'; end if;
  with m as (
    select mu.*,
           case when position(' | ' in coalesce(mu.descricao, '')) = 0
                  or ltrim(split_part(mu.descricao, ' | ', 1)) ilike 'status original%'
                  or ltrim(split_part(mu.descricao, ' | ', 1)) ilike 'motorista (planilha)%' then ''   -- nome do motorista nunca vira motivo
                else btrim(split_part(mu.descricao, ' | ', 1)) end motivo
      from multas mu
     where mu.data_infracao >= ini_ts and mu.data_infracao < fim_ts and (p_hub is null or mu.hub_id = p_hub))
  select jsonb_build_object(
    'total', (select count(*) from m),
    'valor', (select coalesce(sum(valor), 0) from m),
    'por_status', coalesce((select jsonb_agg(jsonb_build_object('status', status, 'n', n) order by n desc)
                              from (select status::text status, count(*) n from m group by 1) s), '[]'),
    'por_hub', coalesce((select jsonb_agg(jsonb_build_object('hub_id', hub_id, 'hub', hub, 'n', n, 'valor', valor) order by n desc, valor desc)
                           from (select m.hub_id, coalesce(h.nome, 'Sem hub') hub, count(*) n, coalesce(sum(m.valor), 0) valor
                                   from m left join hubs h on h.id = m.hub_id group by 1, 2) s), '[]'),
    'motivos', coalesce((select jsonb_agg(jsonb_build_object('texto', motivo, 'n', n, 'valor', valor))
                           from (select motivo, count(*) n, coalesce(sum(valor), 0) valor from m group by 1) s), '[]')
  ) into r;
  r := r || jsonb_build_object(
    'pendentes_lideranca', (select count(*) from multas mu where mu.status = 'aguardando_retorno_lideranca' and (p_hub is null or mu.hub_id = p_hub)),
    'pendentes_alerta', (select count(*) from v_multas_detalhe d where d.status = 'aguardando_retorno_lideranca' and d.alerta_lideranca_sem_retorno and (p_hub is null or d.hub_id = p_hub)),
    'ultima_infracao', (select max((data_infracao at time zone 'America/Sao_Paulo')::date) from multas));
  return r;
end $$;

revoke all on function frota.exec_multas(date, date, uuid) from public, anon;
grant execute on function frota.exec_multas(date, date, uuid) to authenticated;
