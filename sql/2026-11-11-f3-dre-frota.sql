-- Financeiro F3 (aprovado e aplicado em 11/11/2026): DRE da frota por hub e por BU — regras do Jefferson de 11/11/2026
-- 6 contas: Aluguel | Combustível | Pedágio/Estac. | Lavagem | Garagem | Manutenção ("Outras" extinta).
-- Sede (MOURISCO) sempre zerada: tudo que cai nela, sem hub ou em placa fora do cadastro é redistribuído entre os hubs operacionais.
--   * Aluguel: cada locadora pelos carros ativos dela em cada hub; locadora sem carro identificado (ex.: ARVAL) pela frota ativa.
--   * Combustível de nota na sede (ex.: VERSA FUEL): entre os hubs que tiveram nota de combustível local no mês (posto), pelo valor
--     dessas notas; mês sem posto local → pelo gasto Ticket Log de cada hub. Hub novo com posto entra sozinho.
--   * Taxa de gestão Ticket Log = NF da Ticket Log − extrato do mês (se positiva): Combustível, pelo gasto Ticket Log de cada hub.
--   * Diferença Edenred = NFs da Edenred − extrato do mês (se positiva, ex.: NF 26046 de 10/2026): Pedágio/Estac., pela frota ativa.
--   * Ticket Log sem hub: pelo gasto Ticket Log. Edenred sem hub/sede (tags, mensalidades, placa fora do cadastro): frota ativa.
--   * Demais contas de nota na sede/sem hub: frota ativa.
-- Categoria → conta da DRE em categorias_custo.conta_dre ('fora_dre' = só informativo; vazio = "a classificar", também fora e avisado).
-- Cartão: combustível, lavagem; "outros" (conserto de pneu, óleo) → Manutenção; pedágio, estacionamento e tags → Pedágio/Estac.

alter table frota.categorias_custo add column if not exists conta_dre text
  check (conta_dre in ('aluguel', 'combustivel', 'pedagio_estacionamento', 'lavagem', 'garagem', 'manutencao', 'fora_dre'));
alter table frota.hubs add column if not exists sede boolean not null default false;

-- configuração inicial (por id)
update frota.categorias_custo set conta_dre = 'aluguel'                where id = 'ebcf9c60-a60a-4552-bc1b-f00eaede5597'; -- LOCAÇÃO VEICULAR
update frota.categorias_custo set conta_dre = 'combustivel'            where id = '6e42a81c-128b-4579-b14b-514b85fc0a0a'; -- COMBUSTÍVEL
update frota.categorias_custo set conta_dre = 'pedagio_estacionamento' where id = 'cc6178f3-75c1-4cd4-9a67-2d3d085e16a1'; -- PEDAGIO E ESTACIONAMENTO EXTERNO
update frota.categorias_custo set conta_dre = 'lavagem'                where id = 'fa4751b5-a505-4ef5-afd7-f725bbdfdf13'; -- LAVAGEM VEICULAR
update frota.categorias_custo set conta_dre = 'garagem'                where id = '51885e02-f697-4c82-a370-9fb56422007a'; -- GARAGEM
update frota.categorias_custo set conta_dre = 'manutencao'             where id = '4d79e354-c8dc-4188-b85c-bf9436c86188'; -- MANUTENÇÃO VEICULAR
update frota.categorias_custo set conta_dre = 'fora_dre'               where id = '9d8070bc-1ff7-415d-b5ad-8f72c5480aee'; -- LAVANDERIA (saindo da frota)
update frota.categorias_custo set conta_dre = 'fora_dre'               where id = '4f43f474-09df-4333-9868-9942ad8cd739'; -- TELEMETRIA (informativo)
update frota.categorias_custo set conta_dre = 'fora_dre'               where id = '4df3216c-6973-495d-9de7-909453002619'; -- MULTAS DE TRÂNSITO (informativo)
update frota.categorias_custo set conta_dre = 'manutencao'             where id = 'f82838cf-37e4-499c-be2f-4809ebaae7bd'; -- Preparação da Frota (no hub da nota)
-- a classificar (sem regra ainda): SINISTRO, DIGITALIZAÇÃO E DOCUMENTOS
update frota.hubs set sede = true where id = '57861ba4-a7af-4550-9cad-d3b98675fa05'; -- MOURISCO

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
      from nf n left join posto_parte pp on true left join tl_parte tp on not exists (select 1 from posto_parte)
     where n.conta = 'combustivel' and (n.hub_id is null or n.hub_id not in (select id from op))
    union all
    select fp.hub_id, n.conta, n.valor * fp.parte from nf n cross join frota_parte fp
     where n.conta not in ('aluguel', 'combustivel') and (n.hub_id is null or n.hub_id not in (select id from op))
    union all
    select c.hub_id, c.conta, c.valor from cartao c where c.hub_id in (select id from op)
    union all
    select tp.hub_id, c.conta, c.valor * tp.parte from cartao c cross join tl_parte tp
     where c.origem = 'ticket_log' and (c.hub_id is null or c.hub_id not in (select id from op))
    union all
    select fp.hub_id, c.conta, c.valor * fp.parte from cartao c cross join frota_parte fp
     where c.origem <> 'ticket_log' and (c.hub_id is null or c.hub_id not in (select id from op))
    union all
    select tp.hub_id, 'combustivel', t.valor * tp.parte from taxa_tl t cross join tl_parte tp where t.valor > 0
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

-- Por BU: cada hub pelos % dele na aba Rateio (linha Total para hub fora da planilha); mês sem rateio → "(sem rateio)"
create or replace function frota.financeiro_dre_bu(p_mes date)
returns table (bu text, aluguel numeric, combustivel numeric, pedagio_estacionamento numeric,
               lavagem numeric, garagem numeric, manutencao numeric, total numeric)
language plpgsql stable security definer set search_path = frota, public as $$
declare v_mes date := date_trunc('month', p_mes)::date;
begin
  if not frota.posso_ver('financeiro') then raise exception 'Sem permissão para ver o Financeiro.'; end if;
  return query
  with f as (select * from frota.financeiro_dre(v_mes)),
  r as (
    select f.*, coalesce(rh.bu_nome, rt.bu_nome, '(sem rateio)') as bu_x, coalesce(rh.percentual, rt.percentual, 1) as pct
      from f
      left join frota.financeiro_rateio_bu rh on rh.mes_competencia = v_mes and rh.hub_id = f.hub_id
      left join frota.financeiro_rateio_bu rt on rt.mes_competencia = v_mes and rt.hub_id is null
                                              and not exists (select 1 from frota.financeiro_rateio_bu x where x.mes_competencia = v_mes and x.hub_id = f.hub_id)
  )
  select bu_x, round(sum(r.aluguel * pct), 2), round(sum(r.combustivel * pct), 2), round(sum(r.pedagio_estacionamento * pct), 2),
         round(sum(r.lavagem * pct), 2), round(sum(r.garagem * pct), 2), round(sum(r.manutencao * pct), 2), round(sum(r.total * pct), 2)
    from r group by bu_x order by bu_x;
end $$;
revoke all on function frota.financeiro_dre_bu(date) from public, anon;
grant execute on function frota.financeiro_dre_bu(date) to authenticated;

-- Fora da DRE (cartões informativos): categorias 'fora_dre' e "a classificar", e diferença da Edenred (NF − extrato)
create or replace function frota.financeiro_dre_informativo(p_mes date)
returns table (item text, tipo text, valor numeric, qtd bigint)
language plpgsql stable security definer set search_path = frota, public as $$
declare v_mes date := date_trunc('month', p_mes)::date;
begin
  if not frota.posso_ver('financeiro') then raise exception 'Sem permissão para ver o Financeiro.'; end if;
  return query
  select coalesce(c.nome, '(sem categoria)'), case when c.conta_dre = 'fora_dre' then 'fora_dre' else 'a_classificar' end, round(sum(n.valor), 2), count(*)
    from notas_fiscais n left join categorias_custo c on c.id = n.categoria_id
   where n.mes_referencia = v_mes and coalesce(n.aprovacao, 'aprovado') = 'aprovado' and (c.conta_dre is null or c.conta_dre = 'fora_dre')
   group by 1, 2
  union all
  select 'Edenred: NF − extrato (distribuído em Pedágio/Estac. pela frota ativa)', 'distribuido',
         round(coalesce((select sum(n.valor) from notas_fiscais n join fornecedores f on f.id = n.fornecedor_id
                          where n.mes_referencia = v_mes and coalesce(n.aprovacao, 'aprovado') = 'aprovado' and f.nome ~* 'EDENRED'), 0)
             - coalesce((select sum(t.valor) from financeiro_transacoes_cartao t where t.mes_competencia = v_mes and t.origem = 'edenred'), 0), 2), null::bigint
  union all
  select 'Ticket Log: taxa de gestão (NF − extrato, distribuída em Combustível pelo gasto Ticket Log)', 'distribuido',
         round(coalesce((select sum(n.valor) from notas_fiscais n join fornecedores f on f.id = n.fornecedor_id
                          where n.mes_referencia = v_mes and coalesce(n.aprovacao, 'aprovado') = 'aprovado' and f.nome ~* 'TICKET'), 0)
             - coalesce((select sum(t.valor) from financeiro_transacoes_cartao t where t.mes_competencia = v_mes and t.origem = 'ticket_log'), 0), 2), null::bigint
   order by 2, 3 desc;
end $$;
revoke all on function frota.financeiro_dre_informativo(date) from public, anon;
grant execute on function frota.financeiro_dre_informativo(date) to authenticated;
