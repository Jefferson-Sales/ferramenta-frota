-- =============================================================================
-- Dash de Manutenção → Excel analítico do "Checklist de retirada por dia" (27/10/2026)
--   checklist_retirada_analitico(p_ini, p_fim, p_hub) → uma linha por veículo ESPERADO em cada
--   dia do período (foto do começo do dia, checklist_frota_esperada), com realizado sim/não e a
--   hora da primeira Retirada enviada no dia (horário de Brasília).
-- Usa a própria checklist_visao_diaria(dia), igual ao dash_manutencao: os totais da planilha
-- batem por construção com as barras do Dash. security invoker (RLS/hubs de quem baixa).
-- Sem nome de motorista: só data, hub, placa, modelo, status e hora.
-- =============================================================================
create or replace function frota.checklist_retirada_analitico(p_ini date, p_fim date, p_hub uuid default null)
returns table(dia date, hub text, placa text, modelo text, realizado boolean, retirada_em timestamptz)
language sql stable security invoker set search_path = frota as $$
  select d.dia, coalesce(h.nome, 'Sem hub'), vd.placa, vd.modelo, vd.fez, vd.retirada_em
    from checklist_frota_esperada_dias d
    cross join lateral checklist_visao_diaria(d.dia) vd
    left join hubs h on h.id = vd.hub_id
   where d.dia between p_ini and p_fim
     and vd.na_lista
     and (p_hub is null or vd.hub_id = p_hub)
   order by d.dia, h.nome nulls last, vd.placa
$$;

revoke all on function frota.checklist_retirada_analitico(date, date, uuid) from public, anon;
grant execute on function frota.checklist_retirada_analitico(date, date, uuid) to authenticated;
