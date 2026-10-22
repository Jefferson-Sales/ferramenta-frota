-- Onda 3: auto-cadastro de motorista pelo checklist.html (aprovado pelo Jefferson em 22/10/2026).
-- Campos do pipe "Cadastro de Motoristas" do Pipefy: nome, matrícula (do RH, digitada pelo motorista),
-- CPF, e-mail, RG, nascimento, estado civil, CNH (nº e validade), foto da CNH, hub (lista), "já possui
-- senha de abastecimento?" + a senha (cifrada desde a gravação). Cargo/centro de custos ficam de fora.
-- O cadastro entra PENDENTE em motoristas_cadastros (não em motoristas); só admin vê/aprova/reprova.
-- Aprovado → vira linha em motoristas (aí o checklist aceita a matrícula). Reprovado → motivo da lista
-- do Pipefy; o motorista vê o motivo ao digitar a matrícula e pode reenviar.
-- Foto da CNH: bucket privado motoristas-cnh, leitura só admin (regra de PII do CLAUDE.md).
-- Proteção: no máx. 3 cadastros por aparelho/IP em 24 h (chaves HMAC do limite de matrícula).
-- E-mail para frota@ a cada cadastro novo (Edge Function alerta-checklist, modo "cadastro"), sem PII.

-- ---------------------------------------------------------------- motoristas: colunas novas
alter table frota.motoristas
  add column email         text,
  add column estado_civil  text,
  add column cnh_foto_path text;   -- caminho no bucket motoristas-cnh (nunca link)

-- ---------------------------------------------------------------- cadastros
create table frota.motoristas_cadastros (
  id                 uuid primary key default gen_random_uuid(),
  status             text not null default 'pendente' check (status in ('pendente', 'aprovado', 'reprovado')),
  nome               text not null,
  matricula          text not null,
  cpf                text not null,            -- formatado 000.000.000-00 (mesmo padrão de motoristas)
  email              text not null,
  rg                 text not null,
  data_nascimento    date not null,
  estado_civil       text not null,
  cnh                text not null,
  cnh_validade       date not null,
  cnh_foto_path      text not null,
  hub_id             uuid not null references frota.hubs(id),
  possui_senha       boolean not null,         -- já tinha senha de abastecimento ou está pedindo uma nova
  senha_cifrada      bytea not null,           -- AES-256, chave motoristas_senha_chave (Vault)
  lgpd_aceite_em     timestamptz not null,
  origem_chaves      text[] not null default '{}', -- HMAC de IP/aparelho (limite de cadastros por dia)
  criado_em          timestamptz not null default now(),
  avaliado_em        timestamptz,
  avaliado_por       uuid,
  avaliado_por_nome  text,
  motivo_reprovacao  text check (motivo_reprovacao in ('cnh_ilegivel', 'cnh_vencimento', 'foto_cnh_ilegivel', 'data_nascimento',
                                                      'rg', 'cpf', 'senha_ja_cadastrada', 'senha_fora_padrao', 'cadastro_duplicado')),
  motorista_id       uuid references frota.motoristas(id),
  alerta_status      text,
  alerta_erro        text
);
create index on frota.motoristas_cadastros (matricula, criado_em desc);
alter table frota.motoristas_cadastros enable row level security;
create policy ver on frota.motoristas_cadastros for select using (frota.meu_papel() = 'admin');
grant select on frota.motoristas_cadastros to authenticated;   -- escrita só pelas funções abaixo
grant all on frota.motoristas_cadastros to service_role;

-- registro de revelação passa a servir também para cadastros pendentes
alter table frota.senha_acessos alter column motorista_id drop not null,
  add column cadastro_id uuid references frota.motoristas_cadastros(id) on delete cascade;

-- ---------------------------------------------------------------- bucket da foto da CNH (só admin lê)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('motoristas-cnh', 'motoristas-cnh', false, 5242880, array['image/jpeg', 'image/png']);
create policy motoristas_cnh_select on storage.objects for select
  using (bucket_id = 'motoristas-cnh' and frota.meu_papel() = 'admin');
-- upload só por URL assinada gerada pela Edge Function (service_role); sem policy de insert/delete

-- ---------------------------------------------------------------- validações
create or replace function frota.cpf_valido(p text) returns boolean language plpgsql immutable as $$
declare d text := regexp_replace(coalesce(p, ''), '\D', '', 'g'); s int; r int; i int;
begin
  if d !~ '^\d{11}$' or d ~ '^(\d)\1{10}$' then return false; end if;
  s := 0; for i in 1..9 loop s := s + substr(d, i, 1)::int * (11 - i); end loop;
  r := (s * 10) % 11; if r = 10 then r := 0; end if;
  if r <> substr(d, 10, 1)::int then return false; end if;
  s := 0; for i in 1..10 loop s := s + substr(d, i, 1)::int * (12 - i); end loop;
  r := (s * 10) % 11; if r = 10 then r := 0; end if;
  return r = substr(d, 11, 1)::int;
end $$;

create or replace function frota.cpf_formatado(p text) returns text language sql immutable as $$
  select regexp_replace(regexp_replace(coalesce(p, ''), '\D', '', 'g'), '^(\d{3})(\d{3})(\d{3})(\d{2})$', '\1.\2.\3-\4')
$$;

-- ---------------------------------------------------------------- registrar (Edge Function, sem login)
create or replace function frota.registrar_cadastro_motorista(p jsonb, p_ip text, p_aparelho text) returns uuid
language plpgsql security definer set search_path = frota as $$
declare
  v_id    uuid := (p->>'id')::uuid;
  v_mat   text := trim(coalesce(p->>'matricula', ''));
  v_cpf   text := frota.cpf_formatado(p->>'cpf');
  v_nasc  date := (p->>'data_nascimento')::date;
  v_val   date := (p->>'cnh_validade')::date;
  v_cnh   text := regexp_replace(coalesce(p->>'cnh', ''), '\D', '', 'g');
  v_senha text := coalesce(p->>'senha', '');
  v_foto  text := 'cadastros/' || (p->>'id') || '/cnh.jpg';
  v_chaves text[] := frota._tentativa_chaves(p_ip, p_aparelho);
begin
  if v_id is null then raise exception 'Cadastro sem id.'; end if;
  if exists (select 1 from motoristas_cadastros where id = v_id) then raise exception 'Este cadastro já foi enviado.'; end if;
  -- limite: 3 cadastros por aparelho/IP em 24 h
  if (select count(*) from motoristas_cadastros where origem_chaves && v_chaves and criado_em > now() - interval '24 hours') >= 3 then
    raise exception 'Limite de cadastros deste aparelho atingido. Tente amanhã ou fale com o time de frota.';
  end if;
  -- campos
  if length(trim(coalesce(p->>'nome', ''))) < 5 or trim(p->>'nome') !~ '\s' then raise exception 'Informe o nome completo.'; end if;
  if v_mat !~ '^\d{1,10}$' then raise exception 'Matrícula deve ter só números.'; end if;
  if not frota.cpf_valido(p->>'cpf') then raise exception 'CPF inválido.'; end if;
  if coalesce(p->>'email', '') !~* '^[^\s@]+@[^\s@]+\.[^\s@]+$' then raise exception 'E-mail inválido.'; end if;
  if length(trim(coalesce(p->>'rg', ''))) < 5 then raise exception 'Informe o RG.'; end if;
  if v_nasc is null or v_nasc > current_date - interval '18 years' or v_nasc < current_date - interval '90 years' then raise exception 'Data de nascimento inválida.'; end if;
  if coalesce(p->>'estado_civil', '') not in ('Solteiro(a)', 'Casado(a)', 'União estável', 'Divorciado(a)', 'Viúvo(a)') then raise exception 'Escolha o estado civil.'; end if;
  if v_cnh !~ '^\d{11}$' then raise exception 'Número da CNH deve ter 11 dígitos.'; end if;
  if v_val is null or v_val < current_date then raise exception 'CNH vencida — não é possível cadastrar.'; end if;
  if not exists (select 1 from hubs where id = (p->>'hub_id')::uuid and ativo) then raise exception 'Escolha o hub.'; end if;
  if (p->>'possui_senha') is null then raise exception 'Responda se já possui senha de abastecimento.'; end if;
  if v_senha !~ '^\d{4,8}$' then raise exception 'A senha de abastecimento deve ter de 4 a 8 números.'; end if;
  if coalesce((p->>'lgpd')::boolean, false) is not true then raise exception 'É preciso aceitar o uso dos dados para o cadastro.'; end if;
  if not exists (select 1 from storage.objects where bucket_id = 'motoristas-cnh' and name = v_foto) then raise exception 'Envie a foto da CNH.'; end if;
  -- duplicidades
  if exists (select 1 from motoristas where matricula = v_mat) or exists (select 1 from usuarios_perfil where matricula = v_mat) then
    raise exception 'Esta matrícula já tem cadastro. Use "Sou Motorista" e informe a matrícula.';
  end if;
  if exists (select 1 from motoristas where cpf = v_cpf) then raise exception 'Este CPF já tem cadastro. Fale com o time de frota.'; end if;
  if exists (select 1 from motoristas_cadastros where status = 'pendente' and (matricula = v_mat or cpf = v_cpf)) then
    raise exception 'Já existe um cadastro em análise para esta matrícula ou CPF.';
  end if;

  insert into motoristas_cadastros (id, nome, matricula, cpf, email, rg, data_nascimento, estado_civil, cnh, cnh_validade,
                                    cnh_foto_path, hub_id, possui_senha, senha_cifrada, lgpd_aceite_em, origem_chaves)
  values (v_id, trim(p->>'nome'), v_mat, v_cpf, lower(trim(p->>'email')), trim(p->>'rg'), v_nasc, p->>'estado_civil', v_cnh, v_val,
          v_foto, (p->>'hub_id')::uuid, (p->>'possui_senha')::boolean,
          extensions.pgp_sym_encrypt(v_senha, frota._senha_chave(), 'cipher-algo=aes256'), now(), v_chaves);
  return v_id;
end $$;

-- Situação do último cadastro de uma matrícula (para o checklist avisar "em análise" / "reprovado")
create or replace function frota.cadastro_motorista_status(p_matricula text)
returns table (status text, motivo_reprovacao text, criado_em timestamptz)
language sql stable security definer set search_path = frota as $$
  select c.status, c.motivo_reprovacao, c.criado_em from motoristas_cadastros c
   where c.matricula = trim(p_matricula) and c.status in ('pendente', 'reprovado')
     and not exists (select 1 from motoristas m where m.matricula = trim(p_matricula))
   order by c.criado_em desc, (c.status = 'pendente') desc limit 1   -- empate: o pendente vence
$;

revoke all on function frota.registrar_cadastro_motorista(jsonb, text, text), frota.cadastro_motorista_status(text) from public, anon, authenticated;
grant execute on function frota.registrar_cadastro_motorista(jsonb, text, text), frota.cadastro_motorista_status(text) to service_role;

-- ---------------------------------------------------------------- aprovar / reprovar / revelar (admin)
create or replace function frota.aprovar_cadastro_motorista(p_cadastro uuid, p_matricula text) returns uuid
language plpgsql security definer set search_path = frota as $$
declare c motoristas_cadastros%rowtype; v_mat text := trim(coalesce(p_matricula, '')); v_mot uuid; v_nome text;
begin
  if frota.meu_papel() is distinct from 'admin' then raise exception 'Apenas administradores aprovam cadastros.'; end if;
  select * into c from motoristas_cadastros where id = p_cadastro for update;
  if not found then raise exception 'Cadastro não encontrado.'; end if;
  if c.status <> 'pendente' then raise exception 'Este cadastro já foi avaliado.'; end if;
  if v_mat !~ '^\d{1,10}$' then raise exception 'Matrícula conferida deve ter só números.'; end if;
  if exists (select 1 from motoristas where matricula = v_mat) or exists (select 1 from usuarios_perfil where matricula = v_mat) then
    raise exception 'A matrícula % já está em uso.', v_mat;
  end if;
  if exists (select 1 from motoristas where cpf = c.cpf) then raise exception 'Já existe motorista com este CPF.'; end if;
  insert into motoristas (nome, cpf, rg, data_nascimento, cnh, cnh_validade, hub_id, matricula, email, estado_civil, cnh_foto_path,
                          senha_abastecimento_cifrada, ativo)
  values (c.nome, c.cpf, c.rg, c.data_nascimento, c.cnh, c.cnh_validade, c.hub_id, v_mat, c.email, c.estado_civil, c.cnh_foto_path,
          c.senha_cifrada, true)
  returning id into v_mot;
  select nome into v_nome from usuarios_perfil where user_id = auth.uid();
  update motoristas_cadastros set status = 'aprovado', matricula = v_mat, motorista_id = v_mot,
         avaliado_em = now(), avaliado_por = auth.uid(), avaliado_por_nome = v_nome
   where id = c.id;
  update senha_acessos set motorista_id = v_mot where cadastro_id = c.id;
  return v_mot;
end $$;

create or replace function frota.reprovar_cadastro_motorista(p_cadastro uuid, p_motivo text) returns void
language plpgsql security definer set search_path = frota as $$
declare v_nome text;
begin
  if frota.meu_papel() is distinct from 'admin' then raise exception 'Apenas administradores reprovam cadastros.'; end if;
  if p_motivo is null or p_motivo not in ('cnh_ilegivel', 'cnh_vencimento', 'foto_cnh_ilegivel', 'data_nascimento', 'rg', 'cpf',
                                          'senha_ja_cadastrada', 'senha_fora_padrao', 'cadastro_duplicado') then
    raise exception 'Escolha o motivo da reprovação.';
  end if;
  select nome into v_nome from usuarios_perfil where user_id = auth.uid();
  update motoristas_cadastros set status = 'reprovado', motivo_reprovacao = p_motivo,
         avaliado_em = now(), avaliado_por = auth.uid(), avaliado_por_nome = v_nome
   where id = p_cadastro and status = 'pendente';
  if not found then raise exception 'Cadastro não encontrado ou já avaliado.'; end if;
end $$;

create or replace function frota.revelar_senha_cadastro(p_cadastro uuid) returns text
language plpgsql security definer set search_path = frota as $$
declare v_senha text; v_nome text;
begin
  if frota.meu_papel() is distinct from 'admin' then raise exception 'Apenas administradores podem revelar a senha de abastecimento.'; end if;
  select extensions.pgp_sym_decrypt(c.senha_cifrada, frota._senha_chave()) into v_senha from motoristas_cadastros c where c.id = p_cadastro;
  if not found then raise exception 'Cadastro não encontrado.'; end if;
  select nome into v_nome from usuarios_perfil where user_id = auth.uid();
  insert into senha_acessos (cadastro_id, user_id, usuario_nome) values (p_cadastro, auth.uid(), v_nome);
  return v_senha;
end $$;

revoke all on function frota.aprovar_cadastro_motorista(uuid, text), frota.reprovar_cadastro_motorista(uuid, text),
  frota.revelar_senha_cadastro(uuid) from public, anon;
grant execute on function frota.aprovar_cadastro_motorista(uuid, text), frota.reprovar_cadastro_motorista(uuid, text),
  frota.revelar_senha_cadastro(uuid) to authenticated;

-- ---------------------------------------------------------------- e-mail para frota@ a cada cadastro novo
create or replace function frota.tg_cadastro_motorista_alerta() returns trigger
language plpgsql security definer set search_path = frota as $$
begin
  begin
    perform net.http_post(
      url := 'https://efmpzjkqiwyuumaoumof.supabase.co/functions/v1/alerta-checklist',
      headers := jsonb_build_object('Content-Type', 'application/json',
        'x-automation-key', (select decrypted_secret from vault.decrypted_secrets where name = 'automation_secret_checklist')),
      body := jsonb_build_object('modo', 'cadastro', 'cadastro_id', new.id));
  exception when others then
    raise warning 'alerta de cadastro não disparado para %: %', new.id, sqlerrm;
  end;
  return new;
end $$;
create trigger cadastro_motorista_alerta after insert on frota.motoristas_cadastros
  for each row execute function frota.tg_cadastro_motorista_alerta();
