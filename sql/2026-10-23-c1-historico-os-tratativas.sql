-- =============================================================================
-- C1 (Visão Executiva → Operação): base para o detalhe dos carros em manutenção
-- 23/10/2026 — aprovado pelo Jefferson.
--   1. ordens_servico.servico_executado  (resumo limpo escrito pelo auxiliar)
--   2. ordens_servico.status_liberacao   (Aguardando orçamento/aprovação · Em reparo ·
--                                          Pronto, aguardando retirada · Liberado)
--   3. os_status_historico  — cada troca de status / status de liberação, gravada por gatilho
--   4. os_tratativas        — conversa do auxiliar com a oficina: só acrescenta, ninguém edita/apaga
--   5. v_os_fases           — quanto tempo a OS ficou em cada status (security_invoker)
-- Não altera nenhum dado existente. (A "foto inicial" das OS em aberto é um INSERT
-- separado, só com aprovação: ver sql/2026-10-23-c1-historico-os-foto-inicial.sql.)
-- =============================================================================

-- ---------------------------------------------------------------- 1 e 2. colunas novas na OS
alter table frota.ordens_servico add column if not exists servico_executado text;
alter table frota.ordens_servico add column if not exists status_liberacao text;
alter table frota.ordens_servico add constraint os_servico_executado_tamanho
  check (servico_executado is null or char_length(servico_executado) <= 2000);
alter table frota.ordens_servico add constraint os_status_liberacao_valido
  check (status_liberacao is null or status_liberacao in ('aguardando_orcamento', 'em_reparo', 'pronto_retirada', 'liberado'));
comment on column frota.ordens_servico.servico_executado is 'Resumo do serviço feito, escrito pelo auxiliar ao concluir/atualizar a OS (leitura da Diretoria).';
comment on column frota.ordens_servico.status_liberacao is 'aguardando_orcamento | em_reparo | pronto_retirada | liberado. OS concluída vira liberado (gatilho).';

-- OS concluída = carro liberado (hoje a conclusão já preenche data_liberacao).
create or replace function frota.tg_os_liberacao_ao_concluir()
returns trigger language plpgsql set search_path = frota, public as $$
begin
  if new.status = 'concluida' then new.status_liberacao := 'liberado'; end if;
  return new;
end $$;
create trigger os_liberacao_ao_concluir
  before insert or update of status on frota.ordens_servico
  for each row execute function frota.tg_os_liberacao_ao_concluir();

-- ---------------------------------------------------------------- 3. histórico de status
create table frota.os_status_historico (
  id             bigint generated always as identity primary key,
  os_id          uuid not null references frota.ordens_servico(id) on delete cascade,
  campo          text not null check (campo in ('status', 'status_liberacao')),
  valor_anterior text,
  valor_novo     text,
  mudou_em       timestamptz not null default now(),
  mudou_por      uuid,          -- auth.uid() de quem mudou (null = sistema/gatilho)
  mudou_por_nome text,
  origem         text not null default 'gatilho' check (origem in ('gatilho', 'implantacao'))
);
create index os_status_historico_os on frota.os_status_historico (os_id, campo, mudou_em);
comment on table frota.os_status_historico is 'Cada troca de status/status de liberação da OS (gatilho). Imutável. Mede tempo por fase a partir de 23/10/2026.';

create or replace function frota.tg_os_registra_status()
returns trigger language plpgsql security definer set search_path = frota, public as $$
declare quem uuid := auth.uid(); nome text;
begin
  if quem is not null then select p.nome into nome from usuarios_perfil p where p.user_id = quem; end if;
  if tg_op = 'INSERT' then
    insert into os_status_historico (os_id, campo, valor_anterior, valor_novo, mudou_por, mudou_por_nome)
      values (new.id, 'status', null, new.status::text, quem, nome);
    if new.status_liberacao is not null then
      insert into os_status_historico (os_id, campo, valor_anterior, valor_novo, mudou_por, mudou_por_nome)
        values (new.id, 'status_liberacao', null, new.status_liberacao, quem, nome);
    end if;
  else
    if new.status is distinct from old.status then
      insert into os_status_historico (os_id, campo, valor_anterior, valor_novo, mudou_por, mudou_por_nome)
        values (new.id, 'status', old.status::text, new.status::text, quem, nome);
    end if;
    if new.status_liberacao is distinct from old.status_liberacao then
      insert into os_status_historico (os_id, campo, valor_anterior, valor_novo, mudou_por, mudou_por_nome)
        values (new.id, 'status_liberacao', old.status_liberacao, new.status_liberacao, quem, nome);
    end if;
  end if;
  return null;
end $$;
create trigger os_registra_status
  after insert or update of status, status_liberacao on frota.ordens_servico
  for each row execute function frota.tg_os_registra_status();

-- ---------------------------------------------------------------- 4. tratativas com a oficina
create table frota.os_tratativas (
  id          uuid primary key default gen_random_uuid(),
  os_id       uuid not null references frota.ordens_servico(id) on delete cascade,
  texto       text not null check (char_length(btrim(texto)) between 3 and 4000),
  autor_id    uuid,
  autor_nome  text,
  criado_em   timestamptz not null default now()
);
create index os_tratativas_os on frota.os_tratativas (os_id, criado_em);
comment on table frota.os_tratativas is 'Histórico da tratativa do auxiliar com a oficina. Só acrescenta: ninguém edita nem apaga.';

-- autor e hora sempre do servidor (o navegador não escolhe)
create or replace function frota.tg_os_tratativa_autor()
returns trigger language plpgsql security definer set search_path = frota, public as $$
begin
  new.autor_id := auth.uid();
  new.autor_nome := (select p.nome from usuarios_perfil p where p.user_id = new.autor_id);
  new.criado_em := now();
  new.texto := btrim(new.texto);
  return new;
end $$;
create trigger os_tratativa_autor before insert on frota.os_tratativas
  for each row execute function frota.tg_os_tratativa_autor();

-- ---------------------------------------------------------------- imutabilidade (as duas tabelas)
-- Só sai junto com a OS (exclusão em cascata); editar ou apagar avulso é recusado, inclusive para admin.
create or replace function frota.tg_historico_imutavel()
returns trigger language plpgsql set search_path = frota, public as $$
begin
  if tg_op = 'DELETE' and not exists (select 1 from ordens_servico o where o.id = old.os_id) then
    return old;   -- a OS inteira foi apagada (cascata)
  end if;
  raise exception 'Registro de histórico não pode ser alterado nem apagado (%).', tg_table_name;
end $$;
create trigger os_status_historico_imutavel before update or delete on frota.os_status_historico
  for each row execute function frota.tg_historico_imutavel();
create trigger os_tratativas_imutavel before update or delete on frota.os_tratativas
  for each row execute function frota.tg_historico_imutavel();

-- ---------------------------------------------------------------- RLS (mesmo padrão das OS: módulo + hub)
alter table frota.os_status_historico enable row level security;
alter table frota.os_tratativas enable row level security;

create policy visualizar_os_status_historico on frota.os_status_historico for select
  using (frota.posso_ver('manutencao') and frota.os_liberada(os_id));
-- sem policy de insert/update/delete: só o gatilho grava

create policy visualizar_os_tratativas on frota.os_tratativas for select
  using (frota.posso_ver('manutencao') and frota.os_liberada(os_id));
create policy registrar_os_tratativa on frota.os_tratativas for insert
  with check ((frota.meu_papel() = 'admin' or frota.tenho_modulo('manutencao')) and frota.os_liberada(os_id));

revoke all on frota.os_status_historico from anon, authenticated;
revoke all on frota.os_tratativas from anon, authenticated;
grant select on frota.os_status_historico to authenticated;
grant select, insert on frota.os_tratativas to authenticated;

-- ---------------------------------------------------------------- 5. tempo em cada status
-- Uma linha por período: valor, início, fim (próxima troca; null se é o atual) e duração.
-- OS concluída/cancelada: o último período não conta tempo (fim = início).
create or replace view frota.v_os_fases with (security_invoker = true) as
select h.os_id, h.campo, h.valor_novo as valor, h.mudou_em as inicio,
       case when lead(h.mudou_em) over w is not null then lead(h.mudou_em) over w
            when h.valor_novo in ('concluida', 'cancelada', 'liberado') then h.mudou_em
            else null end as fim,
       coalesce(lead(h.mudou_em) over w,
                case when h.valor_novo in ('concluida', 'cancelada', 'liberado') then h.mudou_em else now() end) - h.mudou_em as duracao,
       lead(h.mudou_em) over w is null as atual,
       h.origem
from frota.os_status_historico h
window w as (partition by h.os_id, h.campo order by h.mudou_em, h.id);
grant select on frota.v_os_fases to authenticated;

-- ajuste aplicado em seguida (migration c1_v_os_fases_permissoes): a view herdou permissões
-- largas do padrão do schema; fica só leitura para logados.
revoke all on frota.v_os_fases from anon, authenticated;
grant select on frota.v_os_fases to authenticated;

-- ajuste (migration c1_v_os_fases_segundos_e_quem): a view ganhou duracao_seg (segundos,
-- para o painel não precisar interpretar o formato de intervalo) e mudou_por_nome.
create or replace view frota.v_os_fases with (security_invoker = true) as
select h.os_id, h.campo, h.valor_novo as valor, h.mudou_em as inicio,
       case when lead(h.mudou_em) over w is not null then lead(h.mudou_em) over w
            when h.valor_novo in ('concluida', 'cancelada', 'liberado') then h.mudou_em
            else null end as fim,
       coalesce(lead(h.mudou_em) over w,
                case when h.valor_novo in ('concluida', 'cancelada', 'liberado') then h.mudou_em else now() end) - h.mudou_em as duracao,
       lead(h.mudou_em) over w is null as atual,
       h.origem,
       extract(epoch from coalesce(lead(h.mudou_em) over w,
                case when h.valor_novo in ('concluida', 'cancelada', 'liberado') then h.mudou_em else now() end) - h.mudou_em)::bigint as duracao_seg,
       h.mudou_por_nome
from frota.os_status_historico h
window w as (partition by h.os_id, h.campo order by h.mudou_em, h.id);
revoke all on frota.v_os_fases from anon, authenticated;
grant select on frota.v_os_fases to authenticated;
