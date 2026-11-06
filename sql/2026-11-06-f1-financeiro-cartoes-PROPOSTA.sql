-- =============================================================================
-- PROPOSTA (NÃO APLICADA) — Financeiro F1: Controle de Notas + extratos de cartão (Ticket Log e Edenred) + rateio por hub.
-- Pedido do Jefferson em 06/11/2026. Só vai para o banco depois do "aprovado".
--
-- Decisões embutidas (ver o resumo no chat / docs/plano.md):
--   * NÃO cria frota.financeiro_notas: já existe frota.notas_fiscais (1.165 notas, usada pela Visão Executiva — exec_financeiro).
--     Ajusta a existente: número do Pipe (pipefy_card_id) vira chave única → a carga da planilha é idempotente (upsert).
--   * Dados bancários da planilha (banco, agência, conta) e o "RESPONSÁVEL" não entram.
--   * Extratos: NOME MOTORISTA, MATRÍCULA, NÚMERO DO CARTÃO e RESPONSÁVEL são descartados NA LEITURA (no navegador,
--     antes de enviar) — nunca chegam ao banco.
--   * Chave única dos extratos: o código da transação se repete de verdade (Ticket Log: abastecimento + lavagem na mesma
--     parada; Edenred: cobrança, estorno e nova cobrança com o mesmo código). Por isso a chave é
--     (origem, código, subtipo, valor, ocorrência) — ocorrência = 1ª, 2ª… linha idêntica dentro do arquivo.
--   * Estorno entra com valor NEGATIVO (desconta).
-- =============================================================================

-- ---------------------------------------------------------------- 1. notas_fiscais (ajuste)
-- antes: conferir que não há Pipe repetido no banco (hoje: 1.155 Pipes, todos distintos)
create unique index notas_fiscais_pipe_unico on frota.notas_fiscais (pipefy_card_id) where pipefy_card_id is not null;
alter table frota.notas_fiscais
  add column aprovacao      text check (aprovacao in ('aprovado', 'cancelado')),   -- STATUS da planilha
  add column origem_carga   text check (origem_carga in ('planilha', 'manual')),
  add column importado_em   timestamptz;
comment on column frota.notas_fiscais.pipefy_card_id is 'NÚMERO DO PIPE da planilha CONTROLE DE NOTAS — chave da carga (upsert).';

-- ---------------------------------------------------------------- 2. transações de cartão
create table frota.financeiro_transacoes_cartao (
  id                    uuid primary key default gen_random_uuid(),
  origem                text not null check (origem in ('ticket_log', 'edenred')),
  transacao_id_externo  text not null,
  ocorrencia            smallint not null default 1 check (ocorrencia >= 1),
  data_hora             timestamptz,                      -- horário de Brasília do extrato
  placa                 text,
  veiculo_id            uuid references frota.veiculos(id),
  hub_id                uuid references frota.hubs(id),
  hub_regra             text not null check (hub_regra in ('cadastro', 'historico_hub', 'informacao_adicional', 'matriz_sem_placa', 'sem_hub')),
  categoria             text not null check (categoria in ('combustivel', 'pedagio', 'estacionamento', 'lavagem', 'taxa_tag', 'outros')),
  subtipo               text not null,                    -- ex.: "Abastecimento", "Lavagem completa", "Estorno Pedágio", "Mensalidade Tag ativa…"
  valor                 numeric(12,2) not null,           -- estorno < 0
  litros                numeric(10,3),
  valor_unitario        numeric(10,4),
  hodometro_informado   numeric(12,1),
  tipo_combustivel      text,
  estabelecimento       text,
  cidade                text,
  uf                    text check (uf ~ '^[A-Z]{2}$'),
  fatura_referencia     text,                             -- Edenred: código da fatura (ex.: 570123); Ticket Log: a definir (o RFCV não traz)
  mes_competencia       date not null check (extract(day from mes_competencia) = 1),
  arquivo_origem        text not null,
  importado_em          timestamptz not null default now(),
  importado_por         uuid default auth.uid(),
  constraint financeiro_transacao_unica unique (origem, transacao_id_externo, subtipo, valor, ocorrencia)
);
create index financeiro_transacoes_comp on frota.financeiro_transacoes_cartao (mes_competencia, hub_id, categoria);
create index financeiro_transacoes_veiculo on frota.financeiro_transacoes_cartao (veiculo_id, data_hora);
comment on table frota.financeiro_transacoes_cartao is 'Extratos Ticket Log (abastecimento/lavagem) e Edenred (pedágio/estacionamento/tag) para rateio por hub. Sem nome, matrícula, cartão ou responsável.';

alter table frota.financeiro_transacoes_cartao enable row level security;
create policy visualizar_transacoes_cartao on frota.financeiro_transacoes_cartao for select using (frota.posso_ver('financeiro'));
create policy importa_transacoes_cartao on frota.financeiro_transacoes_cartao for insert with check (frota.meu_papel() = 'admin');
create policy corrige_transacoes_cartao on frota.financeiro_transacoes_cartao for update
  using (frota.meu_papel() = 'admin') with check (frota.meu_papel() = 'admin');   -- re-carga (upsert) e correção de hub
revoke all on frota.financeiro_transacoes_cartao from anon, authenticated;
grant select, insert, update on frota.financeiro_transacoes_cartao to authenticated;   -- sem delete
grant all on frota.financeiro_transacoes_cartao to service_role;

-- ---------------------------------------------------------------- 3. hub na data do evento
-- Hoje usa o hub ATUAL do carro. Quando a transferência de hub (pacote de melhorias, item 3a) criar
-- frota.veiculos_historico_hub, esta função passa a olhar o histórico — sem mudar quem a usa.
create or replace function frota.hub_do_veiculo_na_data(p_veiculo uuid, p_quando timestamptz) returns uuid
language sql stable security invoker set search_path = frota, public as $$
  select v.hub_id from veiculos v where v.id = p_veiculo
$$;

-- ---------------------------------------------------------------- 4. matriz de fechamento (Hub × conta)
create or replace view frota.v_fechamento_hub with (security_invoker = true) as
with nf as (
  select n.mes_referencia as mes, n.hub_id,
         case when c.nome ilike 'LOCAÇÃO%' then 'aluguel' when c.nome ilike 'COMBUST%' then 'combustivel'
              when c.nome ilike 'PEDAGIO%' then 'pedagio_estacionamento' when c.nome ilike 'LAVAGEM%' then 'lavagem'
              when c.nome ilike 'GARAGEM%' then 'garagem' else 'outras' end as coluna,
         n.valor
  from frota.notas_fiscais n
  left join frota.categorias_custo c on c.id = n.categoria_id
  left join frota.fornecedores f on f.id = n.fornecedor_id
  where coalesce(n.aprovacao, 'aprovado') = 'aprovado'
    and coalesce(f.nome, '') !~* '(TICKET|EDENRED)'          -- a NF do cartão vira conciliação; o rateio vem do extrato
), cartao as (
  select t.mes_competencia as mes, t.hub_id,
         case t.categoria when 'combustivel' then 'combustivel' when 'lavagem' then 'lavagem'
              when 'outros' then 'outras' else 'pedagio_estacionamento' end as coluna,
         t.valor
  from frota.financeiro_transacoes_cartao t
)
select mes, hub_id, coluna, sum(valor) as valor
from (select * from nf union all select * from cartao) x
group by mes, hub_id, coluna;

-- ---------------------------------------------------------------- 5. conciliação (extrato × NF do cartão)
create or replace function frota.financeiro_conciliacao(p_mes date)
returns table (origem text, extrato numeric, notas numeric, diferenca numeric, linhas_sem_hub bigint)
language sql stable security invoker set search_path = frota, public as $$
  with ext as (
    select t.origem, sum(t.valor) v, count(*) filter (where t.hub_id is null) sem_hub
    from financeiro_transacoes_cartao t where t.mes_competencia = p_mes group by t.origem
  ), nf as (
    select case when f.nome ~* 'TICKET' then 'ticket_log' else 'edenred' end origem, sum(n.valor) v
    from notas_fiscais n join fornecedores f on f.id = n.fornecedor_id
    where n.mes_referencia = p_mes and f.nome ~* '(TICKET|EDENRED)' and coalesce(n.aprovacao, 'aprovado') = 'aprovado'
    group by 1
  )
  select coalesce(ext.origem, nf.origem), coalesce(ext.v, 0), coalesce(nf.v, 0), coalesce(ext.v, 0) - coalesce(nf.v, 0), coalesce(ext.sem_hub, 0)
  from ext full join nf on nf.origem = ext.origem
$$;

revoke execute on function frota.financeiro_conciliacao(date) from public, anon;
grant execute on function frota.financeiro_conciliacao(date) to authenticated;
