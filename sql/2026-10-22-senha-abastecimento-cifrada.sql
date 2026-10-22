-- Senha de abastecimento cifrada (aprovado pelo Jefferson em 22/10/2026).
-- Antes: frota.motoristas.senha_abastecimento em texto comum, protegida só pelo RLS (admin lê).
-- Agora: AES-256 (pgcrypto pgp_sym_encrypt) com chave no Vault; o texto comum é apagado na gravação
-- por trigger; admin revela sob demanda por função que registra quem/quando em senha_acessos.
-- Diferente do IP/aparelho do checklist (HMAC, irreversível): aqui precisa ser reversível.
-- Ressalvas aceitas: backups recentes ainda têm o texto antigo até saírem da retenção; quem
-- administra o projeto Supabase tem acesso ao Vault.

-- ================= PASSO 1: estrutura (não altera dado existente) =================
select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'motoristas_senha_chave',
                           'Chave AES da senha de abastecimento dos motoristas');

alter table frota.motoristas add column senha_abastecimento_cifrada bytea;

create table frota.senha_acessos (
  id           bigserial primary key,
  motorista_id uuid not null references frota.motoristas(id) on delete cascade,
  user_id      uuid not null,
  usuario_nome text,
  revelado_em  timestamptz not null default now()
);
alter table frota.senha_acessos enable row level security;
create policy ver on frota.senha_acessos for select using (frota.meu_papel() = 'admin');
grant select on frota.senha_acessos to authenticated;   -- sem policy de escrita: só a função abaixo grava

create or replace function frota._senha_chave() returns text
language sql stable security definer set search_path = frota as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'motoristas_senha_chave'
$$;
revoke all on function frota._senha_chave() from public, anon, authenticated, service_role;

-- Qualquer gravação em senha_abastecimento (auto-cadastro, edição, import) é cifrada e o texto apagado.
create or replace function frota.tg_motorista_cifra_senha() returns trigger
language plpgsql security definer set search_path = frota as $$
begin
  if new.senha_abastecimento is not null then
    new.senha_abastecimento_cifrada := extensions.pgp_sym_encrypt(new.senha_abastecimento, frota._senha_chave(), 'cipher-algo=aes256');
    new.senha_abastecimento := null;
  end if;
  return new;
end $$;
create trigger motorista_cifra_senha before insert or update of senha_abastecimento on frota.motoristas
  for each row execute function frota.tg_motorista_cifra_senha();

-- Revelar: só admin ativo; cada chamada fica registrada.
create or replace function frota.revelar_senha_abastecimento(p_motorista uuid) returns text
language plpgsql security definer set search_path = frota as $$
declare v_senha text; v_nome text;
begin
  if frota.meu_papel() is distinct from 'admin' then
    raise exception 'Apenas administradores podem revelar a senha de abastecimento.';
  end if;
  select extensions.pgp_sym_decrypt(m.senha_abastecimento_cifrada, frota._senha_chave()) into v_senha
    from motoristas m where m.id = p_motorista;
  if not found then raise exception 'Motorista não encontrado.'; end if;
  select u.nome into v_nome from usuarios_perfil u where u.user_id = auth.uid();
  insert into senha_acessos (motorista_id, user_id, usuario_nome) values (p_motorista, auth.uid(), v_nome);
  return v_senha;
end $$;
revoke all on function frota.revelar_senha_abastecimento(uuid) from public, anon;
grant execute on function frota.revelar_senha_abastecimento(uuid) to authenticated;

-- ================= PASSO 2: migração das 506 senhas (aprovada e aplicada em 22/10/2026) =================
-- Resultado conferido: 506 cifradas, 0 em texto comum; revelação de teste registrada em senha_acessos.
do $$
declare n_total int; n_cif int; n_erro int; n_texto int;
begin
  select count(*) into n_total from frota.motoristas where senha_abastecimento is not null;
  update frota.motoristas
     set senha_abastecimento_cifrada = extensions.pgp_sym_encrypt(senha_abastecimento, frota._senha_chave(), 'cipher-algo=aes256')
   where senha_abastecimento is not null and senha_abastecimento_cifrada is null;
  get diagnostics n_cif = row_count;
  select count(*) into n_erro from frota.motoristas
   where senha_abastecimento is not null
     and extensions.pgp_sym_decrypt(senha_abastecimento_cifrada, frota._senha_chave()) is distinct from senha_abastecimento;
  if n_erro > 0 or n_cif <> n_total then
    raise exception 'Conferência falhou: % de % não bateram (cifradas: %). Nada foi alterado.', n_erro, n_total, n_cif;
  end if;
  update frota.motoristas set senha_abastecimento = null where senha_abastecimento is not null;
  get diagnostics n_texto = row_count;
  raise notice 'Cifradas: %, conferidas: %, texto apagado: %', n_cif, n_total, n_texto;
end $$;
alter table frota.motoristas add constraint senha_abastecimento_sempre_cifrada check (senha_abastecimento is null);
