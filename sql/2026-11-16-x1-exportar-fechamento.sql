-- X1 (16/11/2026): dados do botão "Exportar fechamento" (planilha do Financeiro), numa chamada só.
-- Pedido do Jefferson: sem a conta Manutenção; MOURISCO (sede) zerado e redistribuído (regra da F3, já dentro de
-- financeiro_dre); rateio por BU = percentuais importados no mês (financeiro_rateio_bu, F2); nomes da planilha.
-- Somente leitura. security definer com a mesma checagem das funções da DRE (quem vê o Financeiro);
-- devolve só agregados e a lista de notas do mês (sem dado bancário, sem nome de pessoa).

create or replace function frota.financeiro_exportar_fechamento(p_mes date)
returns jsonb language plpgsql stable security definer set search_path = frota, public as $$
declare v_mes date := date_trunc('month', p_mes)::date; v_fim date; r jsonb;
begin
  if not frota.posso_ver('financeiro') then raise exception 'Sem permissão para ver o Financeiro.'; end if;
  v_fim := (v_mes + interval '1 month')::date;
  select jsonb_build_object(
    'mes', to_char(v_mes, 'YYYY-MM'),
    -- DRE por hub operacional (sede já zerada e redistribuída), sem manutenção
    'dre', coalesce((select jsonb_agg(jsonb_build_object('hub', d.hub, 'aluguel', d.aluguel, 'combustivel', d.combustivel,
                     'pedagio_estacionamento', d.pedagio_estacionamento, 'lavagem', d.lavagem, 'garagem', d.garagem) order by d.hub)
                     from frota.financeiro_dre(v_mes) d), '[]'),
    -- total por BU calculado pelo sistema (conferência da planilha)
    'dre_bu', coalesce((select jsonb_agg(jsonb_build_object('bu', b.bu, 'total', b.total - b.manutencao) order by b.bu)
                        from frota.financeiro_dre_bu(v_mes) b), '[]'),
    -- % de cada BU por hub importado no mês (hub vazio = linha "Total" da planilha de rateio)
    'rateio', coalesce((select jsonb_agg(jsonb_build_object('hub', h.nome, 'bu', r.bu_nome, 'percentual', r.percentual) order by h.nome, r.bu_nome)
                        from financeiro_rateio_bu r left join hubs h on h.id = r.hub_id where r.mes_competencia = v_mes), '[]'),
    -- carros por hub e locadora: média diária da foto do dia (sem devolvidos); mês sem foto → cadastro atual
    'frota', coalesce((
      with fotos as (
        select d.dia, d.hub_id, ct.locadora_id from frota_status_diario d join veiculos v on v.id = d.veiculo_id
          left join contratos ct on ct.id = v.contrato_id join hubs h on h.id = d.hub_id
         where d.dia >= v_mes and d.dia < v_fim and d.status::text <> 'devolvido' and not h.sede),
      dias as (select greatest(count(distinct dia), 1)::numeric n from fotos),
      base as (
        select f.hub_id, f.locadora_id, count(*)::numeric / (select n from dias) carros from fotos f group by 1, 2
        union all
        select v.hub_id, ct.locadora_id, count(*)::numeric from veiculos v left join contratos ct on ct.id = v.contrato_id
          join hubs h on h.id = v.hub_id
         where not exists (select 1 from fotos) and v.ativo and v.status::text <> 'devolvido' and not h.sede group by 1, 2)
      select jsonb_agg(jsonb_build_object('hub', h.nome, 'locadora', coalesce(fo.nome, '(sem contrato)'), 'carros', round(b.carros, 2)) order by h.nome, fo.nome)
        from base b join hubs h on h.id = b.hub_id left join fornecedores fo on fo.id = b.locadora_id), '[]'),
    'frota_fonte', case when exists (select 1 from frota_status_diario d where d.dia >= v_mes and d.dia < v_fim)
                        then 'foto diária (' || (select count(distinct dia) from frota_status_diario d where d.dia >= v_mes and d.dia < v_fim) || ' dias)'
                        else 'cadastro atual (mês sem foto diária)' end,
    -- notas do mês das 5 contas da planilha (mesmo filtro da DRE: aprovadas)
    'notas', coalesce((select jsonb_agg(jsonb_build_object('conta', c.nome, 'conta_dre', c.conta_dre, 'fornecedor', f.nome, 'hub', h.nome,
                        'valor', n.valor, 'pipe', case when n.pipefy_card_id like 'TEMP-%' then null else n.pipefy_card_id end,
                        'parte', n.pipe_parte, 'etapa', n.etapa, 'nf', n.numero_nota) order by c.nome, f.nome, n.numero_nota)
                       from notas_fiscais n join categorias_custo c on c.id = n.categoria_id
                       left join fornecedores f on f.id = n.fornecedor_id left join hubs h on h.id = n.hub_id
                      where n.mes_referencia = v_mes and coalesce(n.aprovacao, 'aprovado') = 'aprovado'
                        and c.conta_dre in ('aluguel', 'combustivel', 'pedagio_estacionamento', 'lavagem', 'garagem')), '[]'),
    -- extrato × NF dos cartões
    'conciliacao', coalesce((select jsonb_agg(to_jsonb(x)) from frota.financeiro_conciliacao(v_mes) x), '[]'),
    -- cartão "outros" (pneu, óleo) sai do combustível e vai para Manutenção na DRE: entra na conferência das notas
    'cartao_manutencao', coalesce((select sum(t.valor) from financeiro_transacoes_cartao t where t.mes_competencia = v_mes and t.categoria = 'outros'), 0),
    -- lavagem paga no cartão Ticket Log: a NF é de combustível, mas a DRE põe em Lavagem
    'cartao_lavagem', coalesce((select sum(t.valor) from financeiro_transacoes_cartao t where t.mes_competencia = v_mes and t.categoria = 'lavagem'), 0)
  ) into r;
  return r;
end $$;
revoke all on function frota.financeiro_exportar_fechamento(date) from public, anon;
grant execute on function frota.financeiro_exportar_fechamento(date) to authenticated;
