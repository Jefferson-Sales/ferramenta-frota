-- Financeiro F4 (11/11/2026, pedido do Jefferson): quadrante Financeiro da Visão Executiva com as MESMAS regras da DRE da frota.
-- 1) financeiro_dre: mês sem extrato da Ticket Log (antes de 10/2026) — a NF da Ticket Log inteira vira "taxa" e, sem gasto por hub
--    para ratear, sumia; agora usa a frota ativa (o mesmo vale para o combustível da sede sem posto local).
-- 2) exec_financeiro: mesmo formato (linhas por mês), mas cada linha é uma conta da DRE (Aluguel, Combustível, Pedágio/Estac.,
--    Lavagem, Garagem, Manutenção) calculada por financeiro_dre mês a mês — sem canceladas, sem Lavanderia/Multas/Telemetria,
--    sede zerada; com filtro de hub, o valor rateado do hub. Orçado continua vazio até a D1.

create or replace function frota.financeiro_dre(p_mes date)
returns table (hub_id uuid, hub text, aluguel numeric, combustivel numeric, pedagio_estacionamento numeric,
               lavagem numeric, garagem numeric, manutencao numeric, total numeric)
language plpgsql stable security definer set search_path = frota, public as $$
declare v_mes date := date_trunc('month', p_mes)::date;
begin
  if not frota.posso_ver('financeiro') then raise exception 'Sem permissão para ver o Financeiro.'; end if;
  return query
  with op as (select h.id from hubs h where not h.sede),
  fotos as (
    select d.hub_id, ct.locadora_id, count(*)::numeric as carros_dia
      from frota_status_diario d join veiculos v on v.id = d.veiculo_id left join contratos ct on ct.id = v.contrato_id
     where d.dia >= v_mes and d.dia < (v_mes + interval '1 month')::date and d.status::text <> 'devolvido' and d.hub_id in (select id from op)
     group by 1, 2
  ), base_carros as (
    select * from fotos
    union all
    select v.hub_id, ct.locadora_id, 1::numeric from veiculos v left join contratos ct on ct.id = v.contrato_id
     where not exists (select 1 from fotos) and v.ativo and v.status::text <> 'devolvido' and v.hub_id in (select id from op)
  ), por_loc as (
    select b.locadora_id, b.hub_id, sum(b.carros_dia) / sum(sum(b.carros_dia)) over (partition by b.locadora_id) as parte
      from base_carros b group by 1, 2
  ), frota_parte as (
    select b.hub_id, sum(b.carros_dia) / sum(sum(b.carros_dia)) over () as parte from base_carros b group by 1
  ), nf as (
    select n.hub_id, n.fornecedor_id, c.conta_dre as conta, n.valor
      from notas_fiscais n join categorias_custo c on c.id = n.categoria_id left join fornecedores f on f.id = n.fornecedor_id
     where n.mes_referencia = v_mes and coalesce(n.aprovacao, 'aprovado') = 'aprovado'
       and c.conta_dre in ('aluguel', 'combustivel', 'pedagio_estacionamento', 'lavagem', 'garagem', 'manutencao')
       and coalesce(f.nome, '') !~* '(TICKET|EDENRED)'
  ), cartao as (
    select t.hub_id, t.origem,
           case t.categoria when 'combustivel' then 'combustivel' when 'lavagem' then 'lavagem' when 'outros' then 'manutencao'
                else 'pedagio_estacionamento' end as conta, t.valor
      from financeiro_transacoes_cartao t where t.mes_competencia = v_mes
  ), tl_parte as (
    select c.hub_id, sum(c.valor) / nullif(sum(sum(c.valor)) over (), 0) as parte
      from cartao c where c.origem = 'ticket_log' and c.hub_id in (select id from op) group by 1
  ), tl_ef as (
    -- sem extrato da Ticket Log no mês (meses antes da carga dos extratos): usa a frota ativa
    select tl.hub_id, tl.parte from tl_parte tl
    union all
    select fp.hub_id, fp.parte from frota_parte fp where not exists (select 1 from tl_parte)
  ), posto_parte as (
    select n.hub_id, sum(n.valor) / nullif(sum(sum(n.valor)) over (), 0) as parte
      from nf n where n.conta = 'combustivel' and n.hub_id in (select id from op) group by 1
  ), taxa_tl as (
    select greatest(
      coalesce((select sum(n.valor) from notas_fiscais n join fornecedores f on f.id = n.fornecedor_id join categorias_custo c on c.id = n.categoria_id
                 where n.mes_referencia = v_mes and coalesce(n.aprovacao, 'aprovado') = 'aprovado' and f.nome ~* 'TICKET' and c.conta_dre = 'combustivel'), 0)
      - coalesce((select sum(c.valor) from cartao c where c.origem = 'ticket_log'), 0), 0) as valor
  ), taxa_ed as (
    select greatest(
      coalesce((select sum(n.valor) from notas_fiscais n join fornecedores f on f.id = n.fornecedor_id
                 where n.mes_referencia = v_mes and coalesce(n.aprovacao, 'aprovado') = 'aprovado' and f.nome ~* 'EDENRED'), 0)
      - coalesce((select sum(c.valor) from cartao c where c.origem = 'edenred'), 0), 0) as valor
  ), pecas as (
    select coalesce(pl.hub_id, fp.hub_id) as hub_id, 'aluguel'::text as conta, n.valor * coalesce(pl.parte, fp.parte) as valor
      from nf n left join por_loc pl on pl.locadora_id = n.fornecedor_id
      left join frota_parte fp on not exists (select 1 from por_loc p2 where p2.locadora_id = n.fornecedor_id)
     where n.conta = 'aluguel'
    union all
    select n.hub_id, n.conta, n.valor from nf n where n.conta <> 'aluguel' and n.hub_id in (select id from op)
    union all
    select coalesce(pp.hub_id, tp.hub_id), 'combustivel', n.valor * coalesce(pp.parte, tp.parte)
      from nf n left join posto_parte pp on true left join tl_ef tp on not exists (select 1 from posto_parte)
     where n.conta = 'combustivel' and (n.hub_id is null or n.hub_id not in (select id from op))
    union all
    select fp.hub_id, n.conta, n.valor * fp.parte from nf n cross join frota_parte fp
     where n.conta not in ('aluguel', 'combustivel') and (n.hub_id is null or n.hub_id not in (select id from op))
    union all
    select c.hub_id, c.conta, c.valor from cartao c where c.hub_id in (select id from op)
    union all
    select tp.hub_id, c.conta, c.valor * tp.parte from cartao c cross join tl_ef tp
     where c.origem = 'ticket_log' and (c.hub_id is null or c.hub_id not in (select id from op))
    union all
    select fp.hub_id, c.conta, c.valor * fp.parte from cartao c cross join frota_parte fp
     where c.origem <> 'ticket_log' and (c.hub_id is null or c.hub_id not in (select id from op))
    union all
    select tp.hub_id, 'combustivel', t.valor * tp.parte from taxa_tl t cross join tl_ef tp where t.valor > 0
    union all
    select fp.hub_id, 'pedagio_estacionamento', t.valor * fp.parte from taxa_ed t cross join frota_parte fp where t.valor > 0
  )
  select h.id, h.nome,
         round(coalesce(sum(p.valor) filter (where p.conta = 'aluguel'), 0), 2),
         round(coalesce(sum(p.valor) filter (where p.conta = 'combustivel'), 0), 2),
         round(coalesce(sum(p.valor) filter (where p.conta = 'pedagio_estacionamento'), 0), 2),
         round(coalesce(sum(p.valor) filter (where p.conta = 'lavagem'), 0), 2),
         round(coalesce(sum(p.valor) filter (where p.conta = 'garagem'), 0), 2),
         round(coalesce(sum(p.valor) filter (where p.conta = 'manutencao'), 0), 2),
         round(coalesce(sum(p.valor), 0), 2)
    from hubs h left join pecas p on p.hub_id = h.id
   where not h.sede
   group by h.id, h.nome
  having coalesce(sum(p.valor), 0) <> 0
   order by h.nome;
end $$;
revoke all on function frota.financeiro_dre(date) from public, anon;
grant execute on function frota.financeiro_dre(date) to authenticated;

create or replace function frota.exec_financeiro(p_desde date, p_hub uuid default null)
returns jsonb language plpgsql stable set search_path = frota, public as $$
declare
  v_ini date := date_trunc('month', p_desde)::date;
  v_fim date := greatest(date_trunc('month', (now() at time zone 'America/Sao_Paulo')::date)::date,
                         coalesce((select date_trunc('month', max(n.mes_referencia))::date from notas_fiscais n), v_ini));
  r jsonb;
begin
  with meses as (select generate_series(v_ini, v_fim, interval '1 month')::date as mes),
  d as (select m.mes, x.* from meses m cross join lateral frota.financeiro_dre(m.mes) x where p_hub is null or x.hub_id = p_hub),
  contas(chave, nome) as (values ('aluguel', 'Aluguel'), ('combustivel', 'Combustível'), ('pedagio_estacionamento', 'Pedágio/Estac.'),
                                 ('lavagem', 'Lavagem'), ('garagem', 'Garagem'), ('manutencao', 'Manutenção')),
  l as (
    select d.mes, c.chave, c.nome,
           sum(case c.chave when 'aluguel' then d.aluguel when 'combustivel' then d.combustivel
                            when 'pedagio_estacionamento' then d.pedagio_estacionamento when 'lavagem' then d.lavagem
                            when 'garagem' then d.garagem else d.manutencao end) as valor
      from d cross join contas c group by 1, 2, 3
  )
  select jsonb_build_object(
    'linhas', coalesce((select jsonb_agg(jsonb_build_object('mes', to_char(l.mes, 'YYYY-MM'), 'categoria_id', l.chave, 'categoria', l.nome,
                                                            'valor', l.valor, 'qtd', null) order by l.mes, l.chave)
                          from l where l.valor <> 0), '[]'::jsonb),
    'categorias', '[]'::jsonb,
    'sem_hub', 0,
    'regra', 'dre') into r;
  return r;
end $$;
