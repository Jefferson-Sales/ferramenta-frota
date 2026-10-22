-- Trava de devolução pendente (Onda 2, aprovada pelo Jefferson em 22/10/2026).
-- Regra: o motorista (matrícula) não envia Retirada de um carro DIFERENTE enquanto tiver Retirada aberta.
--  - Retirada aberta = Retirada enviada a partir da implantação (trava_devolucao_desde) e ainda não fechada.
--  - Fecha por: Devolução do mesmo carro pelo mesmo motorista; nova Retirada do mesmo carro (substitui);
--    ou fechamento pelo painel (exceção: motorista desligado etc.), com motivo obrigatório.
--  - Trava só por motorista: outro motorista devolvendo o carro não fecha a Retirada do primeiro.
--  - Devolução e Inspeção técnica nunca são travadas.
-- Rastreabilidade: enviado_em (hora do servidor) já existia em todo checklist; aqui entram fechada_em,
-- como/por quem fechou e primeira_trava_em (1ª vez que o motorista foi barrado por esta Retirada).

alter table frota.checklists
  add column fechada_em            timestamptz,
  add column fechada_como          text check (fechada_como in ('devolucao', 'nova_retirada_mesmo_carro', 'painel')),
  add column fechada_por_checklist uuid references frota.checklists(id),
  add column fechada_painel_por    uuid,
  add column fechada_painel_nome   text,
  add column fechada_painel_motivo text,
  add column primeira_trava_em     timestamptz,
  add column qtd_travas            int not null default 0;

-- data de corte = momento da implantação (os 3 checklists de teste de 21/10 não travam ninguém)
do $$ begin
  execute format('create or replace function frota.trava_devolucao_desde() returns timestamptz language sql immutable as %L',
                 'select ' || quote_literal(now()::text) || '::timestamptz');
end $$;

-- Retirada aberta do motorista em OUTRO carro (a mais recente), ou nada.
create or replace function frota.retirada_pendente(p_matricula text, p_veiculo uuid)
returns table (checklist_id uuid, veiculo_id uuid, placa text, enviado_em timestamptz)
language sql stable security definer set search_path = frota as $$
  select c.id, c.veiculo_id, v.placa, c.enviado_em
    from checklists c join veiculos v on v.id = c.veiculo_id
   where c.tipo = 'retirada' and c.status = 'enviado' and c.fechada_em is null
     and c.colaborador_matricula = p_matricula and c.veiculo_id <> p_veiculo
     and c.enviado_em >= frota.trava_devolucao_desde()
   order by c.enviado_em desc limit 1
$$;

-- Marca que o motorista foi barrado por esta Retirada (rastreio de quem não segue o processo).
create or replace function frota.registrar_trava_devolucao(p_checklist uuid) returns void
language sql security definer set search_path = frota as $$
  update checklists set primeira_trava_em = coalesce(primeira_trava_em, now()), qtd_travas = qtd_travas + 1
   where id = p_checklist and fechada_em is null;
$$;

revoke all on function frota.retirada_pendente(text, uuid), frota.registrar_trava_devolucao(uuid) from public, anon, authenticated;
grant execute on function frota.retirada_pendente(text, uuid), frota.registrar_trava_devolucao(uuid) to service_role;

-- registrar_checklist: mesma função de antes + trava (antes de gravar) + fechamento (depois de finalizar)
create or replace function frota.registrar_checklist(p jsonb, p_preenchido_por uuid default null, p_motorista_id uuid default null)
 returns jsonb
 language plpgsql
 set search_path to 'frota'
as $function$
declare
  v_id      uuid := (p->>'id')::uuid;
  v_veic    veiculos%rowtype;
  v_tipo    tipo_checklist := (p->>'tipo')::tipo_checklist;
  v_mat     text := p->>'colaborador_matricula';
  v_exist   checklists%rowtype;
  v_prefixo text;
  v_falt    text;
  v_res     resultado_checklist;
  v_pend    record;
  x         jsonb;
  o         checklist_anomalias%rowtype;
begin
  if v_id is null then raise exception 'Checklist sem id'; end if;

  select * into v_exist from checklists where id = v_id;
  if found then
    if v_exist.status = 'enviado' then
      return jsonb_build_object('id', v_id, 'resultado', v_exist.resultado, 'repetido', true);
    end if;
    raise exception 'Checklist % já existe como rascunho', v_id;
  end if;

  select * into v_veic from veiculos where id = (p->>'veiculo_id')::uuid and ativo;
  if not found then raise exception 'Veículo não encontrado'; end if;
  v_prefixo := v_veic.placa || '/' || v_id || '/';

  -- trava de devolução (a Edge Function já confere antes; isto é a garantia no banco)
  if v_tipo = 'retirada' then
    select * into v_pend from frota.retirada_pendente(v_mat, v_veic.id);
    if found then
      raise exception 'Devolução pendente do carro % (retirado em %). Faça a devolução antes de retirar outro carro.',
        v_pend.placa, to_char(v_pend.enviado_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI');
    end if;
  end if;

  insert into checklists (id, veiculo_id, motorista_id, data_checklist, tipo, hub_id, km, nivel_combustivel, bateria_pct,
                          colaborador_matricula, colaborador_nome, preenchido_por, observacoes)
  values (v_id, v_veic.id, p_motorista_id, current_date, v_tipo, (p->>'hub_id')::uuid, (p->>'km')::numeric,
          nullif(p->>'nivel_combustivel',''), (p->>'bateria_pct')::smallint,
          v_mat, p->>'colaborador_nome', p_preenchido_por, nullif(trim(p->>'observacoes'),''));

  for x in select * from jsonb_array_elements(coalesce(p->'anomalias','[]')) loop
    insert into checklist_anomalias (id, checklist_id, veiculo_id, grupo, item_codigo, subtipo, descricao, severidade, nova)
    values ((x->>'id')::uuid, v_id, v_veic.id, x->>'grupo', nullif(x->>'item_codigo',''), nullif(x->>'subtipo',''),
            nullif(trim(x->>'descricao'),''), (x->>'severidade')::severidade_anomalia, true);
  end loop;

  for x in select * from jsonb_array_elements(coalesce(p->'confirmacoes','[]')) loop
    select * into o from checklist_anomalias
     where id = (x->>'origem_id')::uuid and veiculo_id = v_veic.id and nova and status in ('aberta','em_reparo');
    if not found then continue; end if;
    insert into checklist_anomalias (checklist_id, veiculo_id, grupo, item_codigo, subtipo, descricao, severidade,
                                     nova, origem_anomalia_id, confirmacao)
    values (v_id, v_veic.id, o.grupo, o.item_codigo, o.subtipo, o.descricao, o.severidade, false, o.id, x->>'confirmacao');
  end loop;

  select string_agg(distinct c.grupo_nome, ', ') into v_falt
    from checklist_itens_catalogo c
   where c.ativo and v_tipo = any(c.tipos)
     and (c.combustiveis is null or v_veic.tipo_combustivel = any(c.combustiveis))
     and not exists (select 1 from jsonb_array_elements_text(coalesce(p->'grupos','[]')) g(val) where g.val = c.grupo);
  if v_falt is not null then raise exception 'Grupos sem resposta: %', v_falt; end if;

  insert into checklist_grupos (checklist_id, grupo, tem_anomalia)
  select v_id, s.val, exists (select 1 from checklist_anomalias a
                           where a.checklist_id = v_id and a.grupo = s.val
                             and (a.nova or a.confirmacao = 'continua'))
    from (select distinct g.val from jsonb_array_elements_text(p->'grupos') g(val)) s;

  for x in select * from jsonb_array_elements(coalesce(p->'fotos','[]')) loop
    if left(x->>'path', length(v_prefixo)) <> v_prefixo
       or not exists (select 1 from storage.objects where bucket_id = 'checklist-fotos' and name = x->>'path') then
      raise exception 'Foto não encontrada no servidor: %', x->>'path';
    end if;
    insert into checklist_fotos (checklist_id, anomalia_id, tipo, storage_path, tamanho_bytes)
    values (v_id, (x->>'anomalia_id')::uuid, (x->>'tipo')::tipo_foto_checklist, x->>'path',
            (select (metadata->>'size')::bigint from storage.objects where bucket_id = 'checklist-fotos' and name = x->>'path'));
  end loop;

  v_res := finalizar_checklist(v_id);

  -- fecha Retiradas abertas deste motorista NESTE carro: pela Devolução, ou substituídas por nova Retirada do mesmo carro
  if v_tipo in ('retirada', 'devolucao') then
    update checklists
       set fechada_em = now(),
           fechada_como = case when v_tipo = 'devolucao' then 'devolucao' else 'nova_retirada_mesmo_carro' end,
           fechada_por_checklist = v_id
     where tipo = 'retirada' and status = 'enviado' and fechada_em is null
       and colaborador_matricula = v_mat and veiculo_id = v_veic.id and id <> v_id;
  end if;

  return jsonb_build_object('id', v_id, 'resultado', v_res, 'repetido', false);
end $function$;

-- Fechamento pelo painel (exceção): quem opera Checklist/Manutenções, só nos hubs dele, com motivo.
create or replace function frota.fechar_devolucao_painel(p_checklist uuid, p_motivo text) returns void
language plpgsql security definer set search_path = frota as $$
declare c checklists%rowtype; v_nome text;
begin
  if not frota.posso_editar_checklist() then raise exception 'Sem permissão para fechar devolução.'; end if;
  if length(trim(coalesce(p_motivo, ''))) < 5 then raise exception 'Informe o motivo (mínimo 5 caracteres).'; end if;
  select * into c from checklists where id = p_checklist for update;
  if not found or c.tipo <> 'retirada' or c.status <> 'enviado' then raise exception 'Retirada não encontrada.'; end if;
  if c.fechada_em is not null then raise exception 'Esta retirada já foi fechada.'; end if;
  if not frota.veiculo_liberado(c.veiculo_id) then raise exception 'Veículo de um hub que não está liberado para você.'; end if;
  select nome into v_nome from usuarios_perfil where user_id = auth.uid();
  update checklists
     set fechada_em = now(), fechada_como = 'painel', fechada_painel_por = auth.uid(),
         fechada_painel_nome = v_nome, fechada_painel_motivo = left(trim(p_motivo), 500)
   where id = c.id;
end $$;
revoke all on function frota.fechar_devolucao_painel(uuid, text) from public, anon;
grant execute on function frota.fechar_devolucao_painel(uuid, text) to authenticated, service_role;

-- Lista de devoluções pendentes (respeita o RLS de quem vê: módulo e hubs)
create or replace view frota.v_devolucoes_pendentes with (security_invoker = true) as
select c.id as checklist_id, c.veiculo_id, v.placa, v.modelo, v.hub_id, c.colaborador_nome,
       c.enviado_em as retirada_em, c.primeira_trava_em, c.qtd_travas
  from frota.checklists c
  join frota.veiculos v on v.id = c.veiculo_id
 where c.tipo = 'retirada' and c.status = 'enviado' and c.fechada_em is null
   and c.enviado_em >= frota.trava_devolucao_desde();
grant select on frota.v_devolucoes_pendentes to authenticated;
