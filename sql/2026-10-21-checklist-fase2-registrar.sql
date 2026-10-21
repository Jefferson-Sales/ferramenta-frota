-- Checklist de Veículo — Fase 2: gravação do checklist numa transação só.
-- Chamada só pela Edge Function `checklist` (service_role), que já validou matrícula/login.
-- Idempotente: se o mesmo id já foi enviado (reenvio após queda de conexão), devolve o resultado.

create or replace function frota.registrar_checklist(p jsonb, p_preenchido_por uuid default null, p_motorista_id uuid default null)
returns jsonb
language plpgsql security invoker set search_path = frota as $$
declare
  v_id      uuid := (p->>'id')::uuid;
  v_veic    veiculos%rowtype;
  v_tipo    tipo_checklist := (p->>'tipo')::tipo_checklist;
  v_exist   checklists%rowtype;
  v_prefixo text;
  v_falt    text;
  v_res     resultado_checklist;
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

  insert into checklists (id, veiculo_id, motorista_id, data_checklist, tipo, hub_id, km, nivel_combustivel, bateria_pct,
                          colaborador_matricula, colaborador_nome, preenchido_por, observacoes)
  values (v_id, v_veic.id, p_motorista_id, current_date, v_tipo, (p->>'hub_id')::uuid, (p->>'km')::numeric,
          nullif(p->>'nivel_combustivel',''), (p->>'bateria_pct')::smallint,
          p->>'colaborador_matricula', p->>'colaborador_nome', p_preenchido_por, nullif(trim(p->>'observacoes'),''));

  -- anomalias novas
  for x in select * from jsonb_array_elements(coalesce(p->'anomalias','[]')) loop
    insert into checklist_anomalias (id, checklist_id, veiculo_id, grupo, item_codigo, subtipo, descricao, severidade, nova)
    values ((x->>'id')::uuid, v_id, v_veic.id, x->>'grupo', nullif(x->>'item_codigo',''), nullif(x->>'subtipo',''),
            nullif(trim(x->>'descricao'),''), (x->>'severidade')::severidade_anomalia, true);
  end loop;

  -- confirmações de anomalias já abertas no veículo
  for x in select * from jsonb_array_elements(coalesce(p->'confirmacoes','[]')) loop
    select * into o from checklist_anomalias
     where id = (x->>'origem_id')::uuid and veiculo_id = v_veic.id and nova and status in ('aberta','em_reparo');
    if not found then continue; end if;  -- já foi resolvida por outro checklist: ignora
    insert into checklist_anomalias (checklist_id, veiculo_id, grupo, item_codigo, subtipo, descricao, severidade,
                                     nova, origem_anomalia_id, confirmacao)
    values (v_id, v_veic.id, o.grupo, o.item_codigo, o.subtipo, o.descricao, o.severidade, false, o.id, x->>'confirmacao');
  end loop;

  -- grupos: todos os do catálogo que se aplicam precisam ter sido respondidos;
  -- "tem anomalia" é derivado do que foi realmente reportado/confirmado.
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

  -- fotos: caminho tem de ser deste checklist e o arquivo tem de existir no bucket
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
  return jsonb_build_object('id', v_id, 'resultado', v_res, 'repetido', false);
end $$;
revoke all on function frota.registrar_checklist(jsonb, uuid, uuid) from public, anon, authenticated;
grant execute on function frota.registrar_checklist(jsonb, uuid, uuid) to service_role;
