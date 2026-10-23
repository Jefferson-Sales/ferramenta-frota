-- =============================================================================
-- C4: quadrante Financeiro da Visão Executiva (23/10/2026)
--   exec_financeiro(p_desde, p_hub) → totais por mês de COMPETÊNCIA (mes_referencia) e
--   linha de conta (categorias_custo), a partir de p_desde; + categorias com orçado.
-- security invoker (RLS do Financeiro). As contas de "mês fechado" (dia 05 do mês
-- seguinte), média dos 3 últimos fechados e projeção do ano ficam em regras.js
-- (Regras.resumoFinanceiro), com teste.
-- Todas as notas entram (os status são de envio/cobrança; não há nota cancelada).
-- Com filtro de hub, notas sem hub ficam de fora — 'sem_hub' diz quantas.
-- =============================================================================
create or replace function frota.exec_financeiro(p_desde date, p_hub uuid default null)
returns jsonb language sql stable security invoker set search_path = frota as $$
  select jsonb_build_object(
    'linhas', coalesce((
      select jsonb_agg(jsonb_build_object('mes', to_char(x.mes, 'YYYY-MM'), 'categoria_id', x.categoria_id,
                                          'categoria', x.categoria, 'valor', x.valor, 'qtd', x.qtd) order by x.mes, x.categoria)
        from (select date_trunc('month', n.mes_referencia)::date mes, n.categoria_id, coalesce(c.nome, 'Sem categoria') categoria,
                     sum(n.valor) valor, count(*) qtd
                from notas_fiscais n left join categorias_custo c on c.id = n.categoria_id
               where n.mes_referencia >= date_trunc('month', p_desde)::date
                 and (p_hub is null or n.hub_id = p_hub)
               group by 1, 2, 3) x), '[]'),
    'categorias', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'nome', c.nome,
                              'orcado_mensal', c.orcado_mensal, 'orcado_anual', c.orcado_anual) order by c.nome)
                              from categorias_custo c), '[]'),
    'sem_hub', case when p_hub is null then 0 else (
      select count(*) from notas_fiscais n where n.hub_id is null and n.mes_referencia >= date_trunc('month', p_desde)::date) end)
$$;

revoke all on function frota.exec_financeiro(date, uuid) from public, anon;
grant execute on function frota.exec_financeiro(date, uuid) to authenticated;
