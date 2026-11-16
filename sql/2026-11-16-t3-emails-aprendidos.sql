-- T3 (16/11/2026): a triagem "aprende" o e-mail que envia as notas de cada fornecedor.
-- Pedido do Jefferson: quando o Financeiro liga na tela uma nota da triagem a um fornecedor, gravar o e-mail de origem
-- no cadastro desse fornecedor, para os próximos e-mails serem identificados sozinhos (mesmo sem CNPJ).
--
-- Desenho:
--  * frota.fornecedores_emails_origem: e-mails que enviam notas de cada fornecedor (separado do contato_email, que é
--    o contato humano e não é sobrescrito). Um fornecedor pode ter vários (sistema de NF, financeiro, pessoa).
--  * o gatilho grava o remetente quando a nota é ligada a um fornecedor PELA TELA (cnpj/email automáticos não ensinam).
--    Religar a nota a outro fornecedor desativa o que ela tinha ensinado (fica registrado, não é apagado).
--  * triagem_achar_fornecedor procura no contato_email E nos e-mails aprendidos; se o e-mail aponta para dois
--    fornecedores ativos (ex.: endereço genérico da prefeitura/plataforma de NFS-e), não escolhe nenhum.
--  * lê admin e quem opera o Financeiro (mesmo acesso da triagem); ninguém grava/apaga pela tela (só o gatilho).

create table frota.fornecedores_emails_origem (
  id uuid primary key default gen_random_uuid(),
  fornecedor_id uuid not null references frota.fornecedores(id),
  email text not null check (email = lower(btrim(email)) and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  origem text not null check (origem in ('triagem', 'cadastro')),
  triagem_id uuid references frota.financeiro_notas_triagem(id),
  ativo boolean not null default true,
  criado_por uuid, criado_por_nome text, criado_em timestamptz not null default now(),
  desativado_por uuid, desativado_em timestamptz, motivo_desativacao text,
  unique (fornecedor_id, email)
);
create index fornecedores_emails_origem_email on frota.fornecedores_emails_origem (email) where ativo;
alter table frota.fornecedores_emails_origem enable row level security;
create policy ver_emails_origem on frota.fornecedores_emails_origem for select to authenticated
  using (frota.meu_papel() = 'admin' or frota.tenho_modulo('financeiro'));
grant select on frota.fornecedores_emails_origem to authenticated;
comment on table frota.fornecedores_emails_origem is 'E-mails que enviam notas de cada fornecedor (aprendidos na Triagem de notas). Usados por triagem_achar_fornecedor.';

-- aprende / desaprende quando a tela troca o fornecedor de uma nota da triagem
create or replace function frota.tg_triagem_aprende_email() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.fornecedor_id is not distinct from old.fornecedor_id or new.remetente is null then return new; end if;
  if old.fornecedor_id is not null then
    update frota.fornecedores_emails_origem
       set ativo = false, desativado_por = auth.uid(), desativado_em = now(), motivo_desativacao = 'Nota da triagem religada a outro fornecedor'
     where triagem_id = new.id and fornecedor_id = old.fornecedor_id and ativo;
  end if;
  if new.fornecedor_id is not null and new.fornecedor_achado_por = 'tela' then
    insert into frota.fornecedores_emails_origem (fornecedor_id, email, origem, triagem_id, criado_por, criado_por_nome)
    values (new.fornecedor_id, new.remetente, 'triagem', new.id, auth.uid(), frota.nome_usuario_atual())
    on conflict (fornecedor_id, email) do update
       set ativo = true, triagem_id = excluded.triagem_id, desativado_por = null, desativado_em = null, motivo_desativacao = null
     where not frota.fornecedores_emails_origem.ativo;
  end if;
  return new;
end $$;
revoke all on function frota.tg_triagem_aprende_email() from public, anon, authenticated;
create trigger triagem_aprende_email after update of fornecedor_id on frota.financeiro_notas_triagem
  for each row execute function frota.tg_triagem_aprende_email();

-- busca do fornecedor: CNPJ primeiro; senão e-mail (contato_email ou aprendido) de UM fornecedor ativo
create or replace function frota.triagem_achar_fornecedor(p_cnpj text, p_email text)
returns table (fornecedor_id uuid, achado_por text) language sql stable set search_path = '' as $$
  with c as (
    select f.id from frota.fornecedores f
     where p_cnpj is not null and f.cnpj = regexp_replace(p_cnpj, '\D', '', 'g') limit 1
  ), candidatos as (
    select f.id from frota.fornecedores f
     where p_email is not null and f.ativo and lower(btrim(f.contato_email)) = lower(btrim(p_email))
    union
    select o.fornecedor_id from frota.fornecedores_emails_origem o join frota.fornecedores f on f.id = o.fornecedor_id
     where p_email is not null and o.ativo and f.ativo and o.email = lower(btrim(p_email))
  ), e as (
    select min(id::text)::uuid as id from candidatos having count(*) = 1
  )
  select id, 'cnpj' from c
  union all
  select id, 'email' from e where not exists (select 1 from c)
  limit 1;
$$;
revoke all on function frota.triagem_achar_fornecedor(text, text) from public, anon, authenticated;
grant execute on function frota.triagem_achar_fornecedor(text, text) to service_role;
