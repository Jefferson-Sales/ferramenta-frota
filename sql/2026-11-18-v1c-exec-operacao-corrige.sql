-- V1c (18/11/2026): corrige exec_operacao — a migration v1b colou a contagem operacional/administrativo também no
-- bloco de contratos (que lê v_pool_km_contrato, sem a tabela "v"), e a Visão Executiva dava
-- 'missing FROM-clause entry for table "v"'. Volta o bloco de contratos ao que era; a disponibilidade fica com a contagem.
CREATE OR REPLACE FUNCTION frota.exec_operacao(p_hub uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'frota'
AS $function$
declare r jsonb := '{}';
begin
  r := r || jsonb_build_object('disponibilidade', (
    select jsonb_build_object(
      'total', count(*), 'operacional', count(*) filter (where v.finalidade = 'operacional'), 'administrativo', count(*) filter (where v.finalidade = 'administrativo'),
      'disponivel', count(*) filter (where v.status = 'disponivel'),
      'indisponivel', count(*) filter (where v.status = 'indisponivel'),
      'em_mobilizacao', count(*) filter (where v.status = 'em_mobilizacao'),
      'desmobilizar', count(*) filter (where v.status = 'desmobilizar'),
      'outros', count(*) filter (where v.status not in ('disponivel', 'indisponivel', 'em_mobilizacao', 'desmobilizar')))
    from veiculos v
    where v.ativo and v.status <> 'devolvido' and hub_liberado(v.hub_id) and (p_hub is null or v.hub_id = p_hub)));

  r := r || jsonb_build_object('preventivas', (
    select jsonb_build_object(
      'vencidas', count(*) filter (where s = 'vencida'),
      'vencendo', count(*) filter (where s = 'vencendo'),
      'sem_plano', count(*) filter (where s = 'sem_plano'))
    from (select situacao_revisao(rs.km_ref, rs.proximo_marco, rs.tem_plano) s
            from v_revisoes_status rs where (p_hub is null or rs.hub_id = p_hub)) x));

  r := r || jsonb_build_object('contratos', (
    select jsonb_build_object(
      'total', count(*),
      'com_excedente', count(*) filter (where p.km_excedente_pool > 0),
      'custo_estimado', coalesce(sum(p.custo_estimado_excedente) filter (where p.km_excedente_pool > 0), 0),
      'lista', coalesce(jsonb_agg(jsonb_build_object(
          'contrato_id', p.contrato_id, 'numero', p.numero_contrato, 'locadora', p.locadora,
          'km_excedente', p.km_excedente_pool, 'pct', p.pct_utilizado_pool,
          'custo', p.custo_estimado_excedente, 'carros', p.qtde_veiculos_ativos)
        order by p.km_excedente_pool desc) filter (where p.km_excedente_pool > 0), '[]'))
    from v_pool_km_contrato p));

  return r;
end $function$;
