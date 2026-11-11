-- Notas Fiscais N1b (11/11/2026, pedido do Jefferson): a régua de recorrência só alerta fornecedores das 6 contas
-- oficiais da DRE da frota (Aluguel, Combustível, Pedágio/Estac., Lavagem, Garagem, Manutenção).
-- Fica de fora: conta fora_dre (Lavanderia, Telemetria, Multas) e categoria sem conta ("a classificar": Sinistro, Digitalização).

create or replace function frota.nf_recorrencia(p_mes date)
returns table (fornecedor_id uuid, fornecedor text, hub_id uuid, hub text, categoria_id uuid, conta text,
               meses_com_nota int, dia_habitual int, valor_medio numeric, ultima_competencia date,
               emitiu_no_mes boolean, situacao text)
language sql stable set search_path = frota, public as $$
  with m as (select date_trunc('month', p_mes)::date as mes,
                    (now() at time zone 'America/Sao_Paulo')::date as hoje),
  hist as (
    select n.fornecedor_id, n.hub_id, n.categoria_id,
           count(distinct date_trunc('month', n.mes_referencia)) as meses,
           round(avg(extract(day from n.data_emissao)))::int as dia,
           round(avg(n.valor), 2) as valor_medio,
           max(date_trunc('month', n.mes_referencia))::date as ultima
      from notas_fiscais n join categorias_custo cc on cc.id = n.categoria_id, m
     where n.mes_referencia >= (m.mes - interval '6 months')::date and n.mes_referencia < m.mes
       and coalesce(n.aprovacao, 'aprovado') = 'aprovado'
       and cc.conta_dre in ('aluguel', 'combustivel', 'pedagio_estacionamento', 'lavagem', 'garagem', 'manutencao')
     group by 1, 2, 3
    having count(distinct date_trunc('month', n.mes_referencia)) >= 3
  )
  select h.fornecedor_id, f.nome, h.hub_id, hb.nome, h.categoria_id, c.nome, h.meses::int, h.dia, h.valor_medio, h.ultima,
         e.existe,
         case when e.existe then 'emitiu'
              when m.mes = date_trunc('month', m.hoje)::date and extract(day from m.hoje) <= coalesce(h.dia, 28) + 3 then 'no_prazo'
              when m.mes > date_trunc('month', m.hoje)::date then 'no_prazo'
              else 'atrasada' end
    from hist h cross join m
    left join fornecedores f on f.id = h.fornecedor_id
    left join hubs hb on hb.id = h.hub_id
    left join categorias_custo c on c.id = h.categoria_id
    cross join lateral (select exists (select 1 from notas_fiscais x
                          where x.fornecedor_id = h.fornecedor_id and x.hub_id is not distinct from h.hub_id
                            and x.categoria_id is not distinct from h.categoria_id
                            and date_trunc('month', x.mes_referencia) = m.mes
                            and coalesce(x.aprovacao, 'aprovado') = 'aprovado') as existe) e
   order by (case when e.existe then 2 else 1 end), f.nome, hb.nome
$$;
revoke all on function frota.nf_recorrencia(date) from public, anon;
grant execute on function frota.nf_recorrencia(date) to authenticated;
