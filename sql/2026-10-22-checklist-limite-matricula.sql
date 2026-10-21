-- Limite de tentativas de matrícula no formulário do checklist (aprovado pelo Jefferson em 21/10/2026).
-- Regra: 5 matrículas erradas em 15 minutos bloqueiam por 15 minutos — contado por aparelho E por IP
-- (qualquer um dos dois que estourar bloqueia). Acertos não contam.
-- LGPD: IP e id do aparelho nunca são gravados como estão — só um código (HMAC-SHA256 com chave
-- secreta do Vault). Os registros são apagados depois de 1 dia.

-- chave secreta do código (fica no Vault, nunca sai do banco)
select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'checklist_tentativas_chave',
                           'Chave do HMAC que cifra IP/aparelho no limite de tentativas de matrícula');

create table frota.checklist_tentativas (
  id         bigserial primary key,
  chave      text not null,          -- HMAC de 'ip:<ip>' ou 'aparelho:<id>'
  criado_em  timestamptz not null default now()
);
create index on frota.checklist_tentativas (chave, criado_em);
alter table frota.checklist_tentativas enable row level security;  -- sem policy: só as funções abaixo acessam
grant all on frota.checklist_tentativas to service_role;

create or replace function frota._tentativa_chaves(p_ip text, p_aparelho text) returns text[]
language sql stable security definer set search_path = frota as $$
  select array_remove(array[
    case when coalesce(p_ip, '') <> '' then encode(extensions.hmac('ip:' || p_ip, s.k, 'sha256'), 'hex') end,
    case when coalesce(p_aparelho, '') <> '' then encode(extensions.hmac('aparelho:' || left(p_aparelho, 100), s.k, 'sha256'), 'hex') end
  ], null)
  from (select decrypted_secret as k from vault.decrypted_secrets where name = 'checklist_tentativas_chave') s
$$;

-- Até quando está bloqueado (null = liberado). Bloqueia quando alguma chave tem 5+ erros nos últimos
-- 15 min; libera 15 min depois do último erro dessa chave.
create or replace function frota.checklist_bloqueado_ate(p_ip text, p_aparelho text) returns timestamptz
language sql stable security definer set search_path = frota as $$
  select max(ultimo) + interval '15 minutes'
    from (select t.chave, max(t.criado_em) as ultimo, count(*) as n
            from checklist_tentativas t
           where t.chave = any(frota._tentativa_chaves(p_ip, p_aparelho))
             and t.criado_em > now() - interval '15 minutes'
           group by t.chave) x
   where x.n >= 5
$$;

create or replace function frota.checklist_registrar_erro(p_ip text, p_aparelho text) returns void
language sql security definer set search_path = frota as $$
  insert into checklist_tentativas (chave) select unnest(frota._tentativa_chaves(p_ip, p_aparelho));
$$;

revoke all on function frota._tentativa_chaves(text, text), frota.checklist_bloqueado_ate(text, text),
  frota.checklist_registrar_erro(text, text) from public, anon, authenticated;
grant execute on function frota.checklist_bloqueado_ate(text, text), frota.checklist_registrar_erro(text, text) to service_role;

-- limpeza diária (03:30 BRT): só os códigos de tentativas com mais de 1 dia
select cron.schedule('checklist-tentativas-limpeza', '30 6 * * *',
  $c$ delete from frota.checklist_tentativas where criado_em < now() - interval '1 day' $c$);
