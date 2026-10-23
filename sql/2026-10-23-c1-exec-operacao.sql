-- =============================================================================
-- C1: quadrante de Operação da Visão Executiva (23/10/2026)
--   exec_operacao(p_hub)      → números do quadrante (um JSON)
--   exec_indisponiveis(p_hub) → detalhe dos carros indisponíveis (clique na disponibilidade)
-- security invoker: valem o RLS e os hubs de quem está vendo (mesmo padrão do dash_manutencao).
-- Disponibilidade = mesma regra do Dash de Gestão de Manutenção: disponíveis ÷ frota ativa
-- (sem devolvidos), com hub_liberado explícito ao ler veiculos.
-- =============================================================================

create or replace function frota.exec_operacao(p_hub uuid default null)
returns jsonb language plpgsql stable security invoker set search_path = frota as $$
declare r jsonb := '{}';
begin
  r := r || jsonb_build_object('disponibilidade', (
    select jsonb_build_object(
      'total', count(*),
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

  -- contratos em pool (km é do contrato inteiro: não filtra por hub)
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
end $$;

-- Detalhe dos indisponíveis: um item por carro indisponível, com a OS que o segura
-- (aberta, fora de agendada/concluída/cancelada, com "parou em" e sem "continua rodando").
-- Tempos por fase vêm do histórico (só existe a partir de 23/10/2026; 'historico_parcial'
-- avisa quando a primeira linha é a foto da implantação).
--   aguardando agendamento = tempo em aguardando_agendamento
--   aguardando execução    = tempo em aguardando_orcamento + aguardando_peca
--   em execução            = tempo em em_execucao
create or replace function frota.exec_indisponiveis(p_hub uuid default null)
returns jsonb language sql stable security invoker set search_path = frota as $$
  select coalesce(jsonb_agg(item order by (item->>'parado_desde') nulls last), '[]')
  from (
    select jsonb_build_object(
      'veiculo_id', v.id, 'placa', v.placa, 'modelo', v.modelo, 'hub', h.nome,
      'parado_desde', coalesce(os.data_parou, v.status_desde),
      'os', case when os.id is null then null else jsonb_build_object(
        'id', os.id, 'tipo', os.tipo, 'motivo', os.motivo, 'status', os.status,
        'status_liberacao', os.status_liberacao, 'previsao_retorno', os.previsao_retorno,
        'servico_executado', os.servico_executado, 'oficina', ofi.nome,
        'seg_agendamento', f.seg_agendamento, 'seg_espera_execucao', f.seg_espera_execucao,
        'seg_execucao', f.seg_execucao, 'historico_parcial', f.parcial,
        'tratativas', t.qtd, 'ultima_tratativa', t.ultima) end
    ) item
    from veiculos v
    left join hubs h on h.id = v.hub_id
    left join lateral (
      select o.* from ordens_servico o
       where o.veiculo_id = v.id and o.status not in ('agendada', 'concluida', 'cancelada')
         and o.data_parou is not null and coalesce(o.veiculo_parado, true)
       order by o.data_parou desc limit 1) os on true
    left join oficinas ofi on ofi.id = os.oficina_id
    left join lateral (
      select sum(duracao_seg) filter (where valor = 'aguardando_agendamento') seg_agendamento,
             sum(duracao_seg) filter (where valor in ('aguardando_orcamento', 'aguardando_peca')) seg_espera_execucao,
             sum(duracao_seg) filter (where valor = 'em_execucao') seg_execucao,
             bool_or(origem = 'implantacao') parcial
        from v_os_fases where os_id = os.id and campo = 'status') f on true
    left join lateral (
      select count(*) qtd,
             (select jsonb_build_object('texto', t2.texto, 'autor', t2.autor_nome, 'quando', t2.criado_em)
                from os_tratativas t2 where t2.os_id = os.id order by t2.criado_em desc limit 1) ultima
        from os_tratativas t1 where t1.os_id = os.id) t on true
    where v.ativo and v.status = 'indisponivel' and hub_liberado(v.hub_id) and (p_hub is null or v.hub_id = p_hub)
  ) x
$$;

revoke all on function frota.exec_operacao(uuid) from public, anon;
revoke all on function frota.exec_indisponiveis(uuid) from public, anon;
grant execute on function frota.exec_operacao(uuid) to authenticated;
grant execute on function frota.exec_indisponiveis(uuid) to authenticated;
