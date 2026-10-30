-- =============================================================================
-- Descontos em folha — Etapa 4d (30/10/2026): anexos (termo assinado e documentos).
-- Arquivos no bucket privado descontos-anexos (criado na Etapa 1: PDF/imagem até 10 MB).
--
-- Tipos:
--   termo              → termo de desconto assinado. Abre: admin e quem opera Multas (decisão da Etapa 1).
--   documento_pessoal  → CNH, RG ou outro documento do motorista. Regra do CLAUDE.md para CNH/RG:
--                        ABRE SÓ ADMIN e cada abertura fica registrada. Quem opera Multas pode ENVIAR
--                        (recebe do líder), mas não abre depois. Caminho {desconto_id}/pessoal/{arquivo};
--                        o nome original do arquivo não é guardado (pode ter o nome da pessoa).
--   outro              → AIT, orçamento, print, comprovante. Abre: admin e quem opera Multas.
--
-- Ninguém apaga registro de anexo: admin DESCARTA (com motivo) — o arquivo continua guardado.
-- Envio e descarte entram na linha do tempo do desconto (descontos_historico).
-- Cada abertura de anexo (link de 5 min) fica em descontos_anexos_acessos (só admin lê).
-- =============================================================================

create table frota.descontos_anexos (
  id                  uuid primary key default gen_random_uuid(),
  desconto_id         uuid not null references frota.descontos_folha(id),
  tipo                text not null check (tipo in ('termo', 'documento_pessoal', 'outro')),
  nome_arquivo        text not null check (length(nome_arquivo) between 1 and 200),
  storage_path        text not null unique,
  tamanho_bytes       integer,
  mime                text,
  enviado_por         uuid,
  enviado_por_nome    text,
  enviado_em          timestamptz not null default now(),
  descartado_em       timestamptz,
  descartado_por      uuid,
  descartado_por_nome text,
  descartado_motivo   text check (length(descartado_motivo) <= 500)
);
create index descontos_anexos_desconto on frota.descontos_anexos (desconto_id, enviado_em);
comment on table frota.descontos_anexos is 'Anexos da esteira de descontos (termo assinado, documento pessoal, outros). Arquivo no bucket descontos-anexos. Não se apaga: admin descarta com motivo.';

create table frota.descontos_anexos_acessos (
  id           uuid primary key default gen_random_uuid(),
  anexo_id     uuid not null references frota.descontos_anexos(id),
  acessado_por uuid not null,
  acessado_em  timestamptz not null default clock_timestamp()
);
create index descontos_anexos_acessos_anexo on frota.descontos_anexos_acessos (anexo_id, acessado_em);
comment on table frota.descontos_anexos_acessos is 'Registro de cada abertura de anexo de desconto (quem e quando). Só admin lê; ninguém altera.';

-- ---------------------------------------------------------------- gatilhos
create or replace function frota.tg_descontos_anexos() returns trigger
language plpgsql security definer set search_path = frota, public as $$
declare
  quem uuid := auth.uid();
  nome text;
  admin boolean := coalesce(frota.meu_papel() = 'admin', false) or auth.uid() is null;
  obj record;
  partes text[];
  ext text;
begin
  if quem is not null then select p.nome into nome from usuarios_perfil p where p.user_id = quem; end if;

  if tg_op = 'DELETE' then
    raise exception 'Anexo não pode ser apagado — use "Descartar" (só admin).';
  end if;

  if tg_op = 'INSERT' then
    partes := string_to_array(new.storage_path, '/');
    if partes[1] is distinct from new.desconto_id::text then raise exception 'O arquivo não é deste desconto.'; end if;
    if new.tipo = 'documento_pessoal' then
      if array_length(partes, 1) <> 3 or partes[2] <> 'pessoal' then raise exception 'Documento pessoal vai na pasta "pessoal" do desconto.'; end if;
    elsif array_length(partes, 1) <> 2 then
      raise exception 'Caminho do arquivo inválido.';
    end if;
    select o.metadata into obj from storage.objects o where o.bucket_id = 'descontos-anexos' and o.name = new.storage_path;
    if not found then raise exception 'Arquivo não encontrado no armazenamento — envie de novo.'; end if;
    new.tamanho_bytes := nullif(obj.metadata->>'size', '')::integer;
    new.mime := obj.metadata->>'mimetype';
    new.nome_arquivo := left(nullif(trim(new.nome_arquivo), ''), 200);
    if new.tipo = 'documento_pessoal' then
      ext := lower(substring(new.storage_path from '\.([A-Za-z0-9]{1,5})$'));
      new.nome_arquivo := 'Documento pessoal' || coalesce('.' || ext, '');
    end if;
    if new.nome_arquivo is null then raise exception 'Informe o nome do arquivo.'; end if;
    new.enviado_por := quem; new.enviado_por_nome := nome; new.enviado_em := now();
    new.descartado_em := null; new.descartado_por := null; new.descartado_por_nome := null; new.descartado_motivo := null;
    return new;
  end if;

  -- UPDATE: só o descarte, só admin, uma vez, com motivo
  if new.id is distinct from old.id or new.desconto_id is distinct from old.desconto_id or new.tipo is distinct from old.tipo
     or new.nome_arquivo is distinct from old.nome_arquivo or new.storage_path is distinct from old.storage_path
     or new.tamanho_bytes is distinct from old.tamanho_bytes or new.mime is distinct from old.mime
     or new.enviado_por is distinct from old.enviado_por or new.enviado_por_nome is distinct from old.enviado_por_nome
     or new.enviado_em is distinct from old.enviado_em then
    raise exception 'Anexo não pode ser alterado — só descartado.';
  end if;
  if old.descartado_em is not null then raise exception 'Anexo já descartado.'; end if;
  if not admin then raise exception 'Só admin descarta anexo.'; end if;
  if not frota.texto_ok(new.descartado_motivo) then raise exception 'Descartar exige o motivo (pelo menos 5 letras).'; end if;
  new.descartado_motivo := trim(new.descartado_motivo);
  new.descartado_em := now(); new.descartado_por := quem; new.descartado_por_nome := nome;
  return new;
end $$;
create trigger descontos_anexos_regras before insert or update or delete on frota.descontos_anexos
  for each row execute function frota.tg_descontos_anexos();

-- linha do tempo do desconto: envio e descarte de anexo
create or replace function frota.tg_descontos_anexos_historico() returns trigger
language plpgsql security definer set search_path = frota, public as $$
declare f frota.fase_desconto;
begin
  if tg_op = 'UPDATE' and (old.descartado_em is not null or new.descartado_em is null) then return new; end if;
  select d.fase into f from descontos_folha d where d.id = new.desconto_id;
  insert into descontos_historico (desconto_id, fase_anterior, fase_nova, observacao, detalhes, origem, mudou_por, mudou_por_nome)
  values (new.desconto_id, f, f,
          case when tg_op = 'UPDATE' then new.descartado_motivo end,
          jsonb_build_object('anexo_acao', case when tg_op = 'INSERT' then 'enviado' else 'descartado' end,
                             'anexo_id', new.id, 'anexo_tipo', new.tipo, 'anexo_nome', new.nome_arquivo),
          'painel',
          case when tg_op = 'INSERT' then new.enviado_por else new.descartado_por end,
          case when tg_op = 'INSERT' then new.enviado_por_nome else new.descartado_por_nome end);
  return new;
end $$;
create trigger descontos_anexos_historico after insert or update on frota.descontos_anexos
  for each row execute function frota.tg_descontos_anexos_historico();

create trigger descontos_anexos_acessos_imutavel before update or delete on frota.descontos_anexos_acessos
  for each row execute function frota.tg_descontos_historico_imutavel();

-- ---------------------------------------------------------------- abrir anexo (registra quem abriu)
-- Devolve o caminho no bucket; o navegador gera o link de 5 min com o login da pessoa (o Storage confere de novo).
create or replace function frota.abrir_anexo_desconto(p_anexo uuid) returns text
language plpgsql security definer set search_path = frota, public as $$
declare a record; admin boolean := coalesce(frota.meu_papel() = 'admin', false);
begin
  if auth.uid() is null then raise exception 'Faça login.'; end if;
  select * into a from descontos_anexos where id = p_anexo;
  if not found then raise exception 'Anexo não encontrado.'; end if;
  if not (admin or frota.tenho_modulo('multas')) then raise exception 'Sem permissão para abrir anexos de descontos.'; end if;
  if a.tipo = 'documento_pessoal' and not admin then raise exception 'Documento pessoal: só admin abre.'; end if;
  insert into descontos_anexos_acessos (anexo_id, acessado_por) values (a.id, auth.uid());
  return a.storage_path;
end $$;

-- ---------------------------------------------------------------- acesso (RLS)
alter table frota.descontos_anexos enable row level security;
alter table frota.descontos_anexos_acessos enable row level security;
create policy visualizar_descontos_anexos on frota.descontos_anexos for select
  using (frota.meu_papel() = 'admin' or frota.tenho_modulo('multas'));
create policy envia_descontos_anexos on frota.descontos_anexos for insert
  with check (frota.meu_papel() = 'admin' or frota.tenho_modulo('multas'));
create policy descarta_descontos_anexos on frota.descontos_anexos for update
  using (frota.meu_papel() = 'admin') with check (frota.meu_papel() = 'admin');
create policy admin_le_descontos_anexos_acessos on frota.descontos_anexos_acessos for select
  using (frota.meu_papel() = 'admin');
revoke all on frota.descontos_anexos, frota.descontos_anexos_acessos from anon, authenticated;
grant select, insert, update on frota.descontos_anexos to authenticated;
grant select on frota.descontos_anexos_acessos to authenticated;
grant all on frota.descontos_anexos, frota.descontos_anexos_acessos to service_role;

-- Storage: documento pessoal ({desconto_id}/pessoal/...) só admin lê (ALTER, não DROP — DROP POLICY trava via MCP)
alter policy descontos_anexos_select on storage.objects
  using (bucket_id = 'descontos-anexos'
         and (frota.meu_papel() = 'admin'
              or (frota.tenho_modulo('multas') and (storage.foldername(name))[2] is distinct from 'pessoal'))
         and frota.desconto_existe_txt((storage.foldername(name))[1]));

revoke execute on function frota.tg_descontos_anexos() from public, anon, authenticated;
revoke execute on function frota.tg_descontos_anexos_historico() from public, anon, authenticated;
revoke execute on function frota.abrir_anexo_desconto(uuid) from public, anon;
grant execute on function frota.abrir_anexo_desconto(uuid) to authenticated;
