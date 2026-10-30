-- =============================================================================
-- Gerenciar acessos: admin redefine a senha de login de um usuário (30/10/2026, pedido do Jefferson).
-- A troca é feita pela Edge Function `usuarios` (ação "senha", só admin ativo). Aqui fica o REGISTRO de cada
-- troca (de quem, por quem, quando, se foi gerada pelo sistema) — nunca a senha. Só admin lê; ninguém altera.
-- =============================================================================
create table frota.senha_login_trocas (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null,                 -- de quem a senha foi trocada
  trocado_por   uuid not null,                 -- admin que trocou
  trocado_em    timestamptz not null default now(),
  senha_gerada  boolean not null
);
create index senha_login_trocas_user on frota.senha_login_trocas (user_id, trocado_em desc);
comment on table frota.senha_login_trocas is 'Registro de cada troca de senha de login feita por um admin (Gerenciar acessos). Não guarda a senha.';

alter table frota.senha_login_trocas enable row level security;
create policy admin_le_senha_login_trocas on frota.senha_login_trocas for select using (frota.meu_papel() = 'admin');
revoke all on frota.senha_login_trocas from anon, authenticated;
grant select on frota.senha_login_trocas to authenticated;
grant select, insert on frota.senha_login_trocas to service_role;

create trigger senha_login_trocas_imutavel before update or delete on frota.senha_login_trocas
  for each row execute function frota.tg_descontos_historico_imutavel();
