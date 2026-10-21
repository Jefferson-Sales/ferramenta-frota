-- Restrição por hub em Manutenções e Qualidade da Frota (21/10/2026).
-- Admin vê tudo. Operador/visualizador só vê veículos, OS, checklists e anomalias dos hubs
-- marcados para ele em frota.usuarios_hubs. Os outros módulos (Cadastro, Multas, Financeiro,
-- Elétricos) não mudam. O hub de um registro é o hub ATUAL do veículo (veiculos.hub_id).
-- Hub novo não entra sozinho na lista de ninguém (decisão do Jefferson).
-- Aplicada em 3 passos: (1) tabela + funções, (2) INSERT dos 12 hubs do Vitor, (3) policies + view.

-- ================= PARTE 1: tabela e funções (não muda nenhuma permissão) =================
create table frota.usuarios_hubs (
  user_id    uuid not null references frota.usuarios_perfil(user_id) on delete cascade,
  hub_id     uuid not null references frota.hubs(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, hub_id)
);
alter table frota.usuarios_hubs enable row level security;
create policy usuarios_hubs_ver on frota.usuarios_hubs for select
  using (user_id = auth.uid() or frota.meu_papel() = 'admin');
create policy usuarios_hubs_admin on frota.usuarios_hubs for all
  using (frota.meu_papel() = 'admin') with check (frota.meu_papel() = 'admin');
grant select, insert, update, delete on frota.usuarios_hubs to authenticated;
grant all on frota.usuarios_hubs to service_role;

-- admin ativo: sempre true. Demais: hub precisa estar na lista dele. Hub nulo: só admin.
create or replace function frota.hub_liberado(p_hub uuid) returns boolean
language sql stable security definer set search_path = frota as $$
  select coalesce((select papel = 'admin' from usuarios_perfil where user_id = auth.uid() and ativo), false)
      or exists (select 1 from usuarios_hubs uh join usuarios_perfil p on p.user_id = uh.user_id
                  where uh.user_id = auth.uid() and p.ativo and uh.hub_id = p_hub)
$$;

create or replace function frota.veiculo_liberado(p_veiculo uuid) returns boolean
language sql stable security definer set search_path = frota as $$
  select frota.hub_liberado((select hub_id from veiculos where id = p_veiculo))
$$;

create or replace function frota.os_liberada(p_os uuid) returns boolean
language sql stable security definer set search_path = frota as $$
  select frota.veiculo_liberado((select veiculo_id from ordens_servico where id = p_os))
$$;

create or replace function frota.checklist_liberado(p_checklist uuid) returns boolean
language sql stable security definer set search_path = frota as $$
  select frota.veiculo_liberado((select veiculo_id from checklists where id = p_checklist))
$$;

-- versões que recebem um pedaço do caminho do arquivo no Storage (texto, pode não ser uuid)
create or replace function frota.os_liberada_txt(p text) returns boolean
language sql stable security definer set search_path = frota as $$
  select case when p ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              then frota.os_liberada(p::uuid) else false end
$$;
create or replace function frota.checklist_liberado_txt(p text) returns boolean
language sql stable security definer set search_path = frota as $$
  select case when p ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              then frota.checklist_liberado(p::uuid) else false end
$$;

revoke all on function frota.hub_liberado(uuid), frota.veiculo_liberado(uuid), frota.os_liberada(uuid),
  frota.checklist_liberado(uuid), frota.os_liberada_txt(text), frota.checklist_liberado_txt(text) from public, anon;
grant execute on function frota.hub_liberado(uuid), frota.veiculo_liberado(uuid), frota.os_liberada(uuid),
  frota.checklist_liberado(uuid), frota.os_liberada_txt(text), frota.checklist_liberado_txt(text) to authenticated, service_role;

-- ================= PARTE 2: hubs do Vitor (aplicada depois da parte 1, antes da 3) =================
insert into frota.usuarios_hubs (user_id, hub_id)
select p.user_id, h.id
  from frota.usuarios_perfil p cross join frota.hubs h
 where p.user_id = (select user_id from frota.usuarios_perfil where nome = 'Vitor Hugo');

-- ================= PARTE 3: policies e view =================
-- Manutenções
alter policy visualizar_ordens_servico on frota.ordens_servico using (frota.posso_ver('manutencao') and frota.veiculo_liberado(veiculo_id));
alter policy operador_manutencao_os on frota.ordens_servico with check (frota.tenho_modulo('manutencao') and frota.veiculo_liberado(veiculo_id));
alter policy operador_manutencao_os_upd on frota.ordens_servico
  using (frota.tenho_modulo('manutencao') and frota.veiculo_liberado(veiculo_id))
  with check (frota.tenho_modulo('manutencao') and frota.veiculo_liberado(veiculo_id));

alter policy visualizar_revisoes_preventivas on frota.revisoes_preventivas using (frota.posso_ver('manutencao') and frota.veiculo_liberado(veiculo_id));
alter policy operador_manutencao_revisoes on frota.revisoes_preventivas with check (frota.tenho_modulo('manutencao') and frota.veiculo_liberado(veiculo_id));
alter policy operador_manutencao_revisoes_upd on frota.revisoes_preventivas
  using (frota.tenho_modulo('manutencao') and frota.veiculo_liberado(veiculo_id))
  with check (frota.tenho_modulo('manutencao') and frota.veiculo_liberado(veiculo_id));

alter policy visualizar_os_pecas on frota.os_pecas using (frota.posso_ver('manutencao') and frota.os_liberada(os_id));
alter policy operador_manutencao_pecas on frota.os_pecas with check (frota.tenho_modulo('manutencao') and frota.os_liberada(os_id));
alter policy operador_manutencao_pecas_upd on frota.os_pecas
  using (frota.tenho_modulo('manutencao') and frota.os_liberada(os_id))
  with check (frota.tenho_modulo('manutencao') and frota.os_liberada(os_id));

alter policy visualizar_os_anexos on frota.os_anexos using (frota.posso_ver('manutencao') and frota.os_liberada(os_id));
alter policy operador_manutencao_os_anexos_ins on frota.os_anexos with check (frota.tenho_modulo('manutencao') and frota.os_liberada(os_id));
alter policy operador_manutencao_os_anexos_del on frota.os_anexos using (frota.tenho_modulo('manutencao') and frota.os_liberada(os_id));

alter policy visualizar_os_checklist on frota.os_checklist_itens using (frota.posso_ver('manutencao') and frota.os_liberada(os_id));
alter policy operador_edita_os_checklist on frota.os_checklist_itens
  using (frota.tenho_modulo('manutencao') and frota.os_liberada(os_id))
  with check (frota.tenho_modulo('manutencao') and frota.os_liberada(os_id));

alter policy operador_manutencao_veiculo_status on frota.veiculos
  using (frota.tenho_modulo('manutencao') and frota.hub_liberado(hub_id))
  with check (frota.tenho_modulo('manutencao') and frota.hub_liberado(hub_id));

-- Qualidade da Frota / checklist
alter policy visualizar_checklists on frota.checklists using (frota.posso_ver_checklist() and frota.veiculo_liberado(veiculo_id));
alter policy operador_manutencao_checklist on frota.checklists with check (frota.posso_editar_checklist() and frota.veiculo_liberado(veiculo_id));
alter policy operador_manutencao_checklist_upd on frota.checklists
  using (frota.posso_editar_checklist() and status = 'rascunho' and frota.veiculo_liberado(veiculo_id))
  with check (frota.posso_editar_checklist() and frota.veiculo_liberado(veiculo_id));

alter policy ver on frota.checklist_anomalias using (frota.posso_ver_checklist() and frota.veiculo_liberado(veiculo_id));
alter policy edita on frota.checklist_anomalias
  using (frota.posso_editar_checklist() and frota.veiculo_liberado(veiculo_id))
  with check (frota.posso_editar_checklist() and frota.veiculo_liberado(veiculo_id));
alter policy ver on frota.checklist_grupos using (frota.posso_ver_checklist() and frota.checklist_liberado(checklist_id));
alter policy edita on frota.checklist_grupos
  using (frota.posso_editar_checklist() and frota.checklist_liberado(checklist_id))
  with check (frota.posso_editar_checklist() and frota.checklist_liberado(checklist_id));
alter policy ver on frota.checklist_fotos using (frota.posso_ver_checklist() and frota.checklist_liberado(checklist_id));
alter policy edita on frota.checklist_fotos
  using (frota.posso_editar_checklist() and frota.checklist_liberado(checklist_id))
  with check (frota.posso_editar_checklist() and frota.checklist_liberado(checklist_id));

-- leituras de apoio criadas para checklist/manutenção (quem tem Cadastro da Frota continua vendo tudo pela outra policy)
alter policy visualizar_veiculos_checklist on frota.veiculos using (frota.posso_ver_checklist() and frota.hub_liberado(hub_id));
alter policy visualizar_hubs_checklist on frota.hubs using (frota.posso_ver_checklist() and frota.hub_liberado(id));

-- Storage: os-anexos = {os_id}/arquivo ; checklist-fotos = {placa}/{checklist_id}/arquivo
alter policy os_anexos_select on storage.objects
  using (bucket_id = 'os-anexos' and frota.posso_ver('manutencao') and frota.os_liberada_txt((storage.foldername(name))[1]));
alter policy os_anexos_insert on storage.objects
  with check (bucket_id = 'os-anexos' and frota.tenho_modulo('manutencao') and frota.os_liberada_txt((storage.foldername(name))[1]));
alter policy os_anexos_delete on storage.objects
  using (bucket_id = 'os-anexos' and (frota.meu_papel() = 'admin'
         or (frota.tenho_modulo('manutencao') and frota.os_liberada_txt((storage.foldername(name))[1]))));
alter policy checklist_fotos_select on storage.objects
  using (bucket_id = 'checklist-fotos' and frota.posso_ver_checklist() and frota.checklist_liberado_txt((storage.foldername(name))[2]));
alter policy checklist_fotos_insert on storage.objects
  with check (bucket_id = 'checklist-fotos' and frota.posso_editar_checklist() and frota.checklist_liberado_txt((storage.foldername(name))[2]));
alter policy checklist_fotos_delete on storage.objects
  using (bucket_id = 'checklist-fotos' and frota.posso_editar_checklist() and frota.checklist_liberado_txt((storage.foldername(name))[2]));

-- v_qualidade_frota parte de veiculos: sem este filtro, quem também tem Cadastro da Frota veria todos os carros
create or replace view frota.v_qualidade_frota with (security_invoker = true) as
SELECT v.id AS veiculo_id, v.placa, v.modelo, v.hub_id,
    u.id AS ultimo_checklist_id, u.tipo AS ultimo_tipo, u.enviado_em AS ultimo_checklist_em,
    u.resultado AS ultimo_resultado, u.km AS ultimo_km,
    CURRENT_DATE - u.enviado_em::date AS dias_desde_ultimo,
    COALESCE(ab.criticas, 0::bigint) AS anomalias_criticas, COALESCE(ab.altas, 0::bigint) AS anomalias_altas,
    COALESCE(ab.medias, 0::bigint) AS anomalias_medias, COALESCE(ab.baixas, 0::bigint) AS anomalias_baixas,
    COALESCE(ab.total, 0::bigint) AS anomalias_abertas
   FROM frota.veiculos v
     LEFT JOIN LATERAL ( SELECT c.id, c.tipo, c.enviado_em, c.resultado, c.km
           FROM frota.checklists c
          WHERE c.veiculo_id = v.id AND c.status = 'enviado'::frota.status_checklist
          ORDER BY c.enviado_em DESC LIMIT 1) u ON true
     LEFT JOIN LATERAL ( SELECT count(*) FILTER (WHERE a.severidade = 'critica') AS criticas,
            count(*) FILTER (WHERE a.severidade = 'alta') AS altas,
            count(*) FILTER (WHERE a.severidade = 'media') AS medias,
            count(*) FILTER (WHERE a.severidade = 'baixa') AS baixas,
            count(*) AS total
           FROM frota.checklist_anomalias a
          WHERE a.veiculo_id = v.id AND a.nova AND a.status = ANY (ARRAY['aberta'::frota.status_anomalia, 'em_reparo'::frota.status_anomalia])) ab ON true
  WHERE v.ativo AND frota.hub_liberado(v.hub_id);
