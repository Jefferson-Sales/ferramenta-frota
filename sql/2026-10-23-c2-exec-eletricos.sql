-- =============================================================================
-- C2: quadrante de Carros Elétricos da Visão Executiva (23/10/2026)
--   exec_eletricos(p_ini, p_fim, p_hub) → um JSON com km, recargas, aluguel, manutenção
-- security invoker: cada parte respeita o RLS de quem vê (telemetria/recargas = Carros
-- Elétricos; aluguel = Cadastro da Frota; manutenção = Manutenções + hub).
-- Datas p_ini/p_fim são dias de Brasília (inclusive).
-- Fontes e limites (23/10/2026):
--   km       = telemetria_diaria (Questar), existe desde 12/10/2026
--   recargas = recargas_eletricas (lançadas à mão pelo formulário; última em 06/10/2026)
--   aluguel  = NF de LOCAÇÃO VEICULAR (ver ajuste no fim do arquivo); contrato só como "previsto"
--   manutenção = valor_total das OS de elétricos no período (OS cancelada fora)
-- Saídas: virão das viagens da Questar (D4) — ainda não existem.
-- =============================================================================
create or replace function frota.exec_eletricos(p_ini date, p_fim date, p_hub uuid default null)
returns jsonb language plpgsql stable security invoker set search_path = frota as $$
declare
  ini_ts timestamptz := (p_ini::timestamp at time zone 'America/Sao_Paulo');
  fim_ts timestamptz := ((p_fim + 1)::timestamp at time zone 'America/Sao_Paulo');
  meses int := (extract(year from p_fim)::int - extract(year from p_ini)::int) * 12
               + extract(month from p_fim)::int - extract(month from p_ini)::int + 1;
  r jsonb := '{}';
begin
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Período inválido.'; end if;

  r := r || jsonb_build_object('carros', (
    select count(*) from veiculos v
     where v.ativo and v.status <> 'devolvido' and v.tipo_combustivel::text = 'eletrico'
       and (p_hub is null or v.hub_id = p_hub)));

  r := r || jsonb_build_object('km', (
    select jsonb_build_object(
      'total', round(coalesce(sum(t.km_rodado), 0)::numeric, 1), 'carros', count(distinct t.veiculo_id), 'dias', count(distinct t.data),
      'por_hub', coalesce((select jsonb_agg(x order by (x->>'km')::numeric desc) from (
          select jsonb_build_object('hub_id', v2.hub_id, 'hub', coalesce(h.nome, 'Sem hub'), 'km', round(sum(t2.km_rodado)::numeric, 1), 'carros', count(distinct t2.veiculo_id)) x
            from telemetria_diaria t2 left join veiculos v2 on v2.id = t2.veiculo_id left join hubs h on h.id = v2.hub_id
           where t2.data between p_ini and p_fim and (p_hub is null or v2.hub_id = p_hub)
           group by v2.hub_id, h.nome) s), '[]'))
    from telemetria_diaria t left join veiculos v on v.id = t.veiculo_id
    where t.data between p_ini and p_fim and (p_hub is null or v.hub_id = p_hub)));
  r := r || jsonb_build_object('telemetria_desde', (select min(data) from telemetria_diaria));

  r := r || jsonb_build_object('recargas', (
    select jsonb_build_object('qtd', count(*), 'valor', coalesce(sum(re.valor), 0), 'kwh', coalesce(sum(re.kwh), 0))
      from recargas_eletricas re left join veiculos v on v.id = re.veiculo_id
     where re.data_hora >= ini_ts and re.data_hora < fim_ts
       and (p_hub is null or coalesce(re.hub_id, v.hub_id) = p_hub)));
  r := r || jsonb_build_object('ultima_recarga', (select max((data_hora at time zone 'America/Sao_Paulo')::date) from recargas_eletricas));

  r := r || jsonb_build_object('aluguel', (
    select jsonb_build_object('mensal', coalesce(sum(c.valor_mensal), 0), 'carros_com_valor', count(c.valor_mensal),
                              'meses', meses, 'periodo', coalesce(sum(c.valor_mensal), 0) * meses)
      from v_cadastro_frota c
     where c.ativo and c.tipo_combustivel::text = 'eletrico' and (p_hub is null or c.hub_id = p_hub)));

  r := r || jsonb_build_object('manutencao', (
    select jsonb_build_object('os', count(*), 'valor', coalesce(sum(o.valor_total), 0))
      from ordens_servico o join veiculos v on v.id = o.veiculo_id
     where v.tipo_combustivel::text = 'eletrico' and o.status <> 'cancelada'
       and coalesce(o.data_conclusao, o.data_parou, o.created_at) >= ini_ts
       and coalesce(o.data_conclusao, o.data_parou, o.created_at) < fim_ts
       and (p_hub is null or v.hub_id = p_hub)));

  return r;
end $$;

revoke all on function frota.exec_eletricos(date, date, uuid) from public, anon;
grant execute on function frota.exec_eletricos(date, date, uuid) to authenticated;

-- =============================================================================
-- Ajuste 23/10/2026 (decisão do Jefferson: "use o valor de locação de veículos"), versão final
-- (aplicada pela migration c2_aluguel_previsto_so_apos_ultima_nf):
-- aluguel por mês = notas fiscais da categoria LOCAÇÃO VEICULAR das locadoras que só alugam
-- elétricos (hoje EvoMob: NF de fev a set/2026, de R$ 13.945 a R$ 173.052);
-- mês DEPOIS da última NF lançada = valor mensal do contrato, marcado "previsto";
-- mês ANTES da última NF e sem nota = 0 (não houve locação — ex.: janeiro/2026).
-- Locadora com elétricos e combustão misturados nunca entra pela nota.
-- Com filtro de hub, fica o contrato (as notas não têm carro nem hub).
-- =============================================================================
create or replace function frota.exec_eletricos(p_ini date, p_fim date, p_hub uuid default null)
returns jsonb language plpgsql stable security invoker set search_path = frota as $$
declare
  ini_ts timestamptz := (p_ini::timestamp at time zone 'America/Sao_Paulo');
  fim_ts timestamptz := ((p_fim + 1)::timestamp at time zone 'America/Sao_Paulo');
  r jsonb := '{}';
begin
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Período inválido.'; end if;

  r := r || jsonb_build_object('carros', (
    select count(*) from veiculos v
     where v.ativo and v.status <> 'devolvido' and v.tipo_combustivel::text = 'eletrico'
       and (p_hub is null or v.hub_id = p_hub)));

  r := r || jsonb_build_object('km', (
    select jsonb_build_object(
      'total', round(coalesce(sum(t.km_rodado), 0)::numeric, 1), 'carros', count(distinct t.veiculo_id), 'dias', count(distinct t.data),
      'por_hub', coalesce((select jsonb_agg(x order by (x->>'km')::numeric desc) from (
          select jsonb_build_object('hub_id', v2.hub_id, 'hub', coalesce(h.nome, 'Sem hub'), 'km', round(sum(t2.km_rodado)::numeric, 1), 'carros', count(distinct t2.veiculo_id)) x
            from telemetria_diaria t2 left join veiculos v2 on v2.id = t2.veiculo_id left join hubs h on h.id = v2.hub_id
           where t2.data between p_ini and p_fim and (p_hub is null or v2.hub_id = p_hub)
           group by v2.hub_id, h.nome) s), '[]'))
    from telemetria_diaria t left join veiculos v on v.id = t.veiculo_id
    where t.data between p_ini and p_fim and (p_hub is null or v.hub_id = p_hub)));
  r := r || jsonb_build_object('telemetria_desde', (select min(data) from telemetria_diaria));

  r := r || jsonb_build_object('recargas', (
    select jsonb_build_object('qtd', count(*), 'valor', coalesce(sum(re.valor), 0), 'kwh', coalesce(sum(re.kwh), 0))
      from recargas_eletricas re left join veiculos v on v.id = re.veiculo_id
     where re.data_hora >= ini_ts and re.data_hora < fim_ts
       and (p_hub is null or coalesce(re.hub_id, v.hub_id) = p_hub)));
  r := r || jsonb_build_object('ultima_recarga', (select max((data_hora at time zone 'America/Sao_Paulo')::date) from recargas_eletricas));

  r := r || jsonb_build_object('aluguel', (
    with meses_p as (
      select generate_series(date_trunc('month', p_ini), date_trunc('month', p_fim), interval '1 month')::date mes),
    contrato as (
      select coalesce(sum(c.valor_mensal), 0) mensal, count(c.valor_mensal) n
        from v_cadastro_frota c
       where c.ativo and c.tipo_combustivel::text = 'eletrico' and (p_hub is null or c.hub_id = p_hub)),
    loc_el as (
      select v.locadora_id from veiculos v
       where v.ativo and v.status <> 'devolvido' and v.locadora_id is not null
       group by v.locadora_id having bool_and(v.tipo_combustivel::text = 'eletrico')),
    nf as (
      select n.mes_referencia mes, sum(n.valor) valor
        from notas_fiscais n join categorias_custo cc on cc.id = n.categoria_id
       where cc.nome ilike 'loca%veic%' and n.fornecedor_id in (select locadora_id from loc_el)
         and p_hub is null
       group by n.mes_referencia),
    ultima as (select max(mes) mes from nf),
    por_mes as (
      select m.mes, nf.valor nf_valor,
             (nf.valor is null and ((select mes from ultima) is null or m.mes > (select mes from ultima))) previsto
        from meses_p m left join nf on nf.mes = m.mes)
    select jsonb_build_object(
      'mensal', (select mensal from contrato), 'carros_com_valor', (select n from contrato),
      'meses', count(*), 'meses_nf', count(*) filter (where nf_valor is not null),
      'meses_previsto', count(*) filter (where previsto),
      'ultima_nf', (select mes from ultima),
      'nf', coalesce(sum(nf_valor), 0),
      'periodo', coalesce(sum(case when nf_valor is not null then nf_valor when previsto then (select mensal from contrato) else 0 end), 0))
    from por_mes));

  r := r || jsonb_build_object('manutencao', (
    select jsonb_build_object('os', count(*), 'valor', coalesce(sum(o.valor_total), 0))
      from ordens_servico o join veiculos v on v.id = o.veiculo_id
     where v.tipo_combustivel::text = 'eletrico' and o.status <> 'cancelada'
       and coalesce(o.data_conclusao, o.data_parou, o.created_at) >= ini_ts
       and coalesce(o.data_conclusao, o.data_parou, o.created_at) < fim_ts
       and (p_hub is null or v.hub_id = p_hub)));

  return r;
end $$;
