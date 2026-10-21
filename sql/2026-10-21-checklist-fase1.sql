-- Checklist de Veículo — Fase 1 (estrutura, catálogo Retirada/Devolução, bucket)
-- Substitui o formulário "Checklist Frota 2026" do Pipefy.
-- Módulo de acesso novo: 'checklist' (auxiliares de frota). Quem tem 'manutencao' também enxerga.
-- Motoristas sem login gravam via Edge Function (service_role), não direto pelo REST.

-- ---------- tipos ----------
create type frota.tipo_checklist      as enum ('retirada','devolucao','inspecao_tecnica');
create type frota.status_checklist    as enum ('rascunho','enviado');
create type frota.resultado_checklist as enum ('ok','atencao','reparo_necessario','urgente');
create type frota.severidade_anomalia as enum ('baixa','media','alta','critica');
create type frota.status_anomalia     as enum ('aberta','em_reparo','resolvida','descartada');
create type frota.tipo_foto_checklist as enum ('anomalia','painel','frontal','traseira');

-- ---------- helpers de acesso ----------
create or replace function frota.posso_ver_checklist() returns boolean
language sql stable security definer set search_path = frota as $$
  select frota.posso_ver('checklist') or frota.posso_ver('manutencao')
$$;
create or replace function frota.posso_editar_checklist() returns boolean
language sql stable security definer set search_path = frota as $$
  select frota.meu_papel() = 'admin' or frota.tenho_modulo('checklist') or frota.tenho_modulo('manutencao')
$$;

-- ---------- matrícula dos auxiliares ----------
alter table frota.usuarios_perfil add column matricula text;
create unique index usuarios_perfil_matricula_uk on frota.usuarios_perfil (matricula) where matricula is not null;

-- Busca nome por matrícula em motoristas e usuarios_perfil (sem expor PII).
create or replace function frota.buscar_colaborador(p_matricula text)
returns table (nome text, origem text, hub_id uuid, motorista_id uuid, user_id uuid)
language sql stable security definer set search_path = frota as $$
  select m.nome, 'motorista', m.hub_id, m.id, null::uuid
    from motoristas m where m.matricula = trim(p_matricula) and m.ativo
  union all
  select u.nome, 'usuario', u.hub_id, null::uuid, u.user_id
    from usuarios_perfil u where u.matricula = trim(p_matricula) and u.ativo
$$;
revoke all on function frota.buscar_colaborador(text) from public, anon;
grant execute on function frota.buscar_colaborador(text) to authenticated, service_role; -- (authenticated revogado no fim)

-- ---------- catálogo de itens ----------
create table frota.checklist_itens_catalogo (
  id                uuid primary key default gen_random_uuid(),
  grupo             text not null,
  grupo_nome        text not null,
  grupo_ordem       int  not null default 0,
  codigo            text not null unique,
  descricao         text not null,
  tipos             frota.tipo_checklist[] not null,
  severidade_padrao frota.severidade_anomalia not null default 'media',
  subtipos          text[],                       -- ex.: luz do painel (Injeção, Óleo...)
  combustiveis      frota.tipo_combustivel[],     -- null = todos; {eletrico,hibrido} = só elétricos
  ordem             int  not null default 0,
  ativo             boolean not null default true,
  created_at        timestamptz default now()
);

-- ---------- cabeçalho (tabela já existente, vazia) ----------
alter table frota.checklists
  alter column data_checklist set default current_date,
  add column tipo                  frota.tipo_checklist,
  add column hub_id                uuid references frota.hubs(id),
  add column km                    numeric,
  add column nivel_combustivel     text check (nivel_combustivel in ('reserva','1/4','1/2','3/4','cheio')),
  add column bateria_pct           smallint check (bateria_pct between 0 and 100),
  add column colaborador_matricula text,
  add column colaborador_nome      text,
  add column preenchido_por        uuid,            -- auth.uid() do auxiliar; null quando motorista sem login
  add column status                frota.status_checklist not null default 'rascunho',
  add column resultado             frota.resultado_checklist,
  add column qtd_anomalias_novas   int not null default 0,
  add column observacoes           text,
  add column enviado_em            timestamptz,
  add column updated_at            timestamptz default now();
create index checklists_veiculo_idx on frota.checklists (veiculo_id, enviado_em desc);

-- ---------- grupos respondidos ----------
create table frota.checklist_grupos (
  id           uuid primary key default gen_random_uuid(),
  checklist_id uuid not null references frota.checklists(id) on delete cascade,
  grupo        text not null,
  tem_anomalia boolean not null,
  unique (checklist_id, grupo)
);

-- ---------- anomalias ----------
-- nova=true: problema reportado pela 1ª vez (é a "raiz" que tem ciclo de vida).
-- nova=false: confirmação de uma anomalia anterior (origem_anomalia_id aponta pra raiz),
--   com confirmacao 'continua' ou 'nao_existe'.
create table frota.checklist_anomalias (
  id                 uuid primary key default gen_random_uuid(),
  checklist_id       uuid not null references frota.checklists(id) on delete cascade,
  veiculo_id         uuid not null references frota.veiculos(id),
  grupo              text not null,
  item_codigo        text references frota.checklist_itens_catalogo(codigo),
  subtipo            text,
  descricao          text,
  severidade         frota.severidade_anomalia not null,
  nova               boolean not null default true,
  origem_anomalia_id uuid references frota.checklist_anomalias(id),
  confirmacao        text check (confirmacao in ('continua','nao_existe')),
  status             frota.status_anomalia not null default 'aberta',
  os_id              uuid references frota.ordens_servico(id),
  resolvida_em       timestamptz,
  created_at         timestamptz default now(),
  check (nova = (origem_anomalia_id is null)),
  check (nova or confirmacao is not null)
);
create index checklist_anomalias_veiculo_idx on frota.checklist_anomalias (veiculo_id, status) where nova;
create index checklist_anomalias_checklist_idx on frota.checklist_anomalias (checklist_id);

-- veiculo_id da anomalia sempre igual ao do checklist
create or replace function frota.tg_anomalia_veiculo() returns trigger
language plpgsql set search_path = frota as $$
begin
  select veiculo_id into new.veiculo_id from checklists where id = new.checklist_id;
  return new;
end $$;
create trigger anomalia_veiculo before insert or update of checklist_id on frota.checklist_anomalias
  for each row execute function frota.tg_anomalia_veiculo();

-- ---------- fotos ----------
create table frota.checklist_fotos (
  id            uuid primary key default gen_random_uuid(),
  checklist_id  uuid not null references frota.checklists(id) on delete cascade,
  anomalia_id   uuid references frota.checklist_anomalias(id) on delete cascade,
  tipo          frota.tipo_foto_checklist not null,
  storage_path  text not null,
  tamanho_bytes bigint,
  created_at    timestamptz default now(),
  check ((tipo = 'anomalia') = (anomalia_id is not null))
);
create index checklist_fotos_checklist_idx on frota.checklist_fotos (checklist_id);

-- ---------- RLS ----------
alter table frota.checklist_itens_catalogo enable row level security;
alter table frota.checklist_grupos        enable row level security;
alter table frota.checklist_anomalias     enable row level security;
alter table frota.checklist_fotos         enable row level security;

-- catálogo não é sensível: o formulário do motorista (sem login) precisa ler
create policy catalogo_leitura on frota.checklist_itens_catalogo for select to anon, authenticated using (ativo or frota.meu_papel() = 'admin');
create policy catalogo_admin   on frota.checklist_itens_catalogo for all to authenticated
  using (frota.meu_papel() = 'admin') with check (frota.meu_papel() = 'admin');

-- checklists: policies existentes redefinidas com ALTER (DROP trava no MCP)
alter policy visualizar_checklists on frota.checklists using (frota.posso_ver_checklist());
alter policy operador_manutencao_checklist on frota.checklists with check (frota.posso_editar_checklist());
alter policy operador_manutencao_checklist_upd on frota.checklists
  using (frota.posso_editar_checklist() and status = 'rascunho') with check (frota.posso_editar_checklist());

create policy ver   on frota.checklist_grupos for select to authenticated using (frota.posso_ver_checklist());
create policy edita on frota.checklist_grupos for all    to authenticated using (frota.posso_editar_checklist()) with check (frota.posso_editar_checklist());
create policy ver   on frota.checklist_anomalias for select to authenticated using (frota.posso_ver_checklist());
create policy edita on frota.checklist_anomalias for all    to authenticated using (frota.posso_editar_checklist()) with check (frota.posso_editar_checklist());
create policy ver   on frota.checklist_fotos for select to authenticated using (frota.posso_ver_checklist());
create policy edita on frota.checklist_fotos for all    to authenticated using (frota.posso_editar_checklist()) with check (frota.posso_editar_checklist());

grant select on frota.checklist_itens_catalogo to anon;
grant select, insert, update, delete on frota.checklist_itens_catalogo, frota.checklist_grupos,
  frota.checklist_anomalias, frota.checklist_fotos to authenticated;
grant all on frota.checklist_itens_catalogo, frota.checklist_grupos,
  frota.checklist_anomalias, frota.checklist_fotos to service_role;

-- ---------- finalizar (valida no servidor e calcula resultado) ----------
create or replace function frota.finalizar_checklist(p_checklist_id uuid)
returns frota.resultado_checklist
language plpgsql security invoker set search_path = frota as $$
declare
  c          checklists%rowtype;
  faltando   text;
  v_result   resultado_checklist;
  v_pior     severidade_anomalia;
  v_novas    int;
begin
  select * into c from checklists where id = p_checklist_id for update;
  if not found then raise exception 'Checklist não encontrado'; end if;
  if c.status <> 'rascunho' then raise exception 'Checklist já foi enviado'; end if;
  if c.tipo is null or c.km is null or c.colaborador_matricula is null then
    raise exception 'Preencha tipo, km e matrícula antes de enviar';
  end if;

  -- grupo marcado "tem problema" precisa ter ao menos uma anomalia
  select string_agg(g.grupo, ', ') into faltando
    from checklist_grupos g
   where g.checklist_id = c.id and g.tem_anomalia
     and not exists (select 1 from checklist_anomalias a where a.checklist_id = c.id and a.grupo = g.grupo);
  if faltando is not null then raise exception 'Grupo marcado com problema sem anomalia: %', faltando; end if;

  -- anomalia nova exige foto
  select string_agg(coalesce(a.item_codigo, a.grupo), ', ') into faltando
    from checklist_anomalias a
   where a.checklist_id = c.id and a.nova
     and not exists (select 1 from checklist_fotos f where f.anomalia_id = a.id);
  if faltando is not null then raise exception 'Anomalia nova sem foto: %', faltando; end if;

  -- inspeção técnica exige fotos fixas
  if c.tipo = 'inspecao_tecnica' then
    select string_agg(t::text, ', ') into faltando
      from unnest(array['painel','frontal','traseira']::tipo_foto_checklist[]) t
     where not exists (select 1 from checklist_fotos f where f.checklist_id = c.id and f.tipo = t);
    if faltando is not null then raise exception 'Faltam fotos obrigatórias: %', faltando; end if;
  end if;

  -- "não existe mais" encerra a anomalia de origem
  update checklist_anomalias o
     set status = 'resolvida', resolvida_em = now()
    from checklist_anomalias a
   where a.checklist_id = c.id and a.confirmacao = 'nao_existe'
     and o.id = a.origem_anomalia_id and o.status in ('aberta','em_reparo');

  select count(*) into v_novas from checklist_anomalias where checklist_id = c.id and nova;

  -- resultado = pior anomalia ainda aberta no veículo
  select max(severidade) into v_pior
    from checklist_anomalias
   where veiculo_id = c.veiculo_id and nova and status in ('aberta','em_reparo');
  v_result := case v_pior when 'critica' then 'urgente' when 'alta' then 'reparo_necessario'
                          when 'media' then 'atencao' when 'baixa' then 'atencao' else 'ok' end;

  update checklists
     set status = 'enviado', enviado_em = now(), updated_at = now(),
         resultado = v_result, qtd_anomalias_novas = v_novas,
         realizado = true, avaria_critica = (v_pior = 'critica')
   where id = c.id;
  return v_result;
end $$;
revoke all on function frota.finalizar_checklist(uuid) from public, anon;
grant execute on function frota.finalizar_checklist(uuid) to authenticated, service_role;

-- ---------- views (security_invoker herda o RLS de quem consulta) ----------
create view frota.v_anomalias_abertas with (security_invoker = true) as
select a.id, a.veiculo_id, v.placa, v.modelo, v.hub_id, a.grupo, a.item_codigo, i.descricao as item_descricao,
       a.subtipo, a.descricao, a.severidade, a.status, a.os_id, a.created_at as reportada_em,
       (current_date - a.created_at::date) as dias_aberta, a.checklist_id,
       (select max(c2.enviado_em) from frota.checklist_anomalias x join frota.checklists c2 on c2.id = x.checklist_id
         where x.origem_anomalia_id = a.id and x.confirmacao = 'continua') as ultima_confirmacao
  from frota.checklist_anomalias a
  join frota.checklists c on c.id = a.checklist_id and c.status = 'enviado'
  join frota.veiculos v on v.id = a.veiculo_id
  left join frota.checklist_itens_catalogo i on i.codigo = a.item_codigo
 where a.nova and a.status in ('aberta','em_reparo');

create view frota.v_qualidade_frota with (security_invoker = true) as
select v.id as veiculo_id, v.placa, v.modelo, v.hub_id,
       u.id as ultimo_checklist_id, u.tipo as ultimo_tipo, u.enviado_em as ultimo_checklist_em,
       u.resultado as ultimo_resultado, u.km as ultimo_km,
       (current_date - u.enviado_em::date) as dias_desde_ultimo,
       coalesce(ab.criticas,0) as anomalias_criticas, coalesce(ab.altas,0) as anomalias_altas,
       coalesce(ab.medias,0) as anomalias_medias, coalesce(ab.baixas,0) as anomalias_baixas,
       coalesce(ab.total,0) as anomalias_abertas
  from frota.veiculos v
  left join lateral (
    select c.* from frota.checklists c
     where c.veiculo_id = v.id and c.status = 'enviado'
     order by c.enviado_em desc limit 1) u on true
  left join lateral (
    select count(*) filter (where severidade='critica') criticas,
           count(*) filter (where severidade='alta') altas,
           count(*) filter (where severidade='media') medias,
           count(*) filter (where severidade='baixa') baixas,
           count(*) total
      from frota.checklist_anomalias a
     where a.veiculo_id = v.id and a.nova and a.status in ('aberta','em_reparo')) ab on true
 where v.ativo;

grant select on frota.v_anomalias_abertas, frota.v_qualidade_frota to authenticated, service_role;

-- ---------- bucket de fotos ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('checklist-fotos','checklist-fotos', false, 5242880,
        array['image/jpeg','image/png','image/webp','image/heic','image/heif']);

create policy checklist_fotos_select on storage.objects for select to authenticated
  using (bucket_id = 'checklist-fotos' and frota.posso_ver_checklist());
create policy checklist_fotos_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'checklist-fotos' and frota.posso_editar_checklist());
create policy checklist_fotos_delete on storage.objects for delete to authenticated
  using (bucket_id = 'checklist-fotos' and frota.posso_editar_checklist());

-- ---------- catálogo: Retirada / Devolução (itens do Pipefy) ----------
insert into frota.checklist_itens_catalogo (grupo, grupo_nome, grupo_ordem, codigo, descricao, tipos, severidade_padrao, subtipos, ordem) values
 ('freios_pneus','Freios e pneus',1,'rd_freio','Freio',            '{retirada,devolucao}','alta',  null,1),
 ('freios_pneus','Freios e pneus',1,'rd_pneus','Pneus',            '{retirada,devolucao}','alta',  null,2),
 ('freios_pneus','Freios e pneus',1,'rd_estepe','Estepe',          '{retirada,devolucao}','media', null,3),
 ('direcao','Direção',2,'rd_direcao','Direção',                    '{retirada,devolucao}','alta',  null,1),
 ('eletrica_painel','Elétrica e painel',3,'rd_luzes_externas','Luzes externas','{retirada,devolucao}','media',null,1),
 ('eletrica_painel','Elétrica e painel',3,'rd_luz_painel','Luz acesa no painel','{retirada,devolucao}','alta',
    '{Injeção,Óleo,Bateria,ABS,Outra}',2),
 ('carroceria_limpeza','Carroceria e limpeza',4,'rd_avaria','Avaria visível','{retirada,devolucao}','baixa',null,1),
 ('carroceria_limpeza','Carroceria e limpeza',4,'rd_limpeza','Limpeza','{retirada,devolucao}','baixa',null,2);

-- ---------- ajustes aplicados depois do teste ----------
-- 1 checklist por veículo/dia impedia Retirada + Devolução no mesmo dia
alter table frota.checklists drop constraint checklists_veiculo_id_data_checklist_key;
-- funções de permissão não precisam ser chamadas por anon
revoke execute on function frota.posso_ver_checklist(), frota.posso_editar_checklist() from public, anon;
grant execute on function frota.posso_ver_checklist(), frota.posso_editar_checklist() to authenticated, service_role;
-- busca por matrícula só pelo servidor (Edge Function), pra ninguém listar nomes via REST
revoke execute on function frota.buscar_colaborador(text) from authenticated;
