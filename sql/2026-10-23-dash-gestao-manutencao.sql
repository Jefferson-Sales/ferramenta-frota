-- Dash de Gestão de Manutenção (23/10/2026).
-- Tudo respeita os hubs de quem vê: funções security invoker (RLS do usuário) + hub_liberado explícito onde se lê veiculos
-- (quem tem Cadastro da Frota enxerga todos os veículos pela policy daquele módulo).

-- 1. Foto diária do status de cada veículo (tendência de disponibilidade a partir de 23/10/2026)
create table if not exists frota.frota_status_diario (
  dia date not null,
  veiculo_id uuid not null references frota.veiculos(id),
  hub_id uuid,
  status frota.status_veiculo not null,
  gerado_em timestamptz not null default now(),
  primary key (dia, veiculo_id)
);
alter table frota.frota_status_diario enable row level security;
create policy visualizar_frota_status_diario on frota.frota_status_diario for select
  using (frota.posso_ver('manutencao') and frota.hub_liberado(hub_id));
grant select on frota.frota_status_diario to authenticated;
grant all on frota.frota_status_diario to service_role;

-- idempotente: gerar duas vezes no mesmo dia não duplica (mantém a primeira foto)
create or replace function frota.gerar_status_diario(p_dia date default (now() at time zone 'America/Sao_Paulo')::date)
returns integer language plpgsql security definer set search_path = frota as $$
declare n integer;
begin
  insert into frota_status_diario (dia, veiculo_id, hub_id, status)
  select p_dia, v.id, v.hub_id, v.status from veiculos v where v.ativo and v.status <> 'devolvido'
  on conflict (dia, veiculo_id) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function frota.gerar_status_diario(date) from public, anon, authenticated;

-- 00:10 de Brasília (03:10 UTC), depois da foto da Visão diária (00:05)
select cron.schedule('frota-status-diario', '10 3 * * *', $cron$ select frota.gerar_status_diario(); $cron$);

-- 2. Números do Dash (um único JSON). p_dias: período em dias (0 = todo o histórico). p_hub: um hub (null = todos os do usuário).
create or replace function frota.dash_manutencao(p_dias integer default 30, p_hub uuid default null)
returns jsonb language plpgsql stable security invoker set search_path = frota as $$
declare
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  ini date := case when coalesce(p_dias, 0) > 0 then hoje - (p_dias - 1) else date '2000-01-01' end;
  ini_ts timestamptz := (ini::timestamp at time zone 'America/Sao_Paulo');
  r jsonb := '{}';
begin
  -- disponibilidade agora
  r := r || jsonb_build_object('disponibilidade', (
    select jsonb_build_object(
      'total', count(*), 'disponivel', count(*) filter (where v.status = 'disponivel'),
      'indisponivel', count(*) filter (where v.status = 'indisponivel'),
      'outros', count(*) filter (where v.status not in ('disponivel', 'indisponivel')),
      'por_hub', coalesce((select jsonb_agg(x order by x->>'hub') from (
          select jsonb_build_object('hub_id', v2.hub_id, 'hub', h.nome, 'total', count(*),
                   'disponivel', count(*) filter (where v2.status = 'disponivel'),
                   'indisponivel', count(*) filter (where v2.status = 'indisponivel')) x
            from veiculos v2 left join hubs h on h.id = v2.hub_id
           where v2.ativo and v2.status <> 'devolvido' and hub_liberado(v2.hub_id) and (p_hub is null or v2.hub_id = p_hub)
           group by v2.hub_id, h.nome) s), '[]'))
      from veiculos v where v.ativo and v.status <> 'devolvido' and hub_liberado(v.hub_id) and (p_hub is null or v.hub_id = p_hub)));

  -- tendência (fotos diárias)
  r := r || jsonb_build_object('tendencia', coalesce((select jsonb_agg(jsonb_build_object('dia', dia, 'total', total, 'disponivel', disp) order by dia) from (
      select f.dia, count(*) total, count(*) filter (where f.status = 'disponivel') disp
        from frota_status_diario f where f.dia >= ini and hub_liberado(f.hub_id) and (p_hub is null or f.hub_id = p_hub)
       group by f.dia) t), '[]'));

  -- OS do período (RLS de ordens_servico já filtra por hub; p_hub pelo hub atual do veículo)
  r := r || jsonb_build_object('oficinas', coalesce((select jsonb_agg(x order by (x->>'custo_total')::numeric desc nulls last) from (
      select jsonb_build_object('oficina', o.nome,
        'qtd_os', count(*),
        'custo_total', coalesce(sum(os.valor_total), 0),
        'concluidas', count(*) filter (where os.status = 'concluida'),
        'com_previsao', count(*) filter (where os.status = 'concluida' and os.previsao_retorno is not null and coalesce(os.data_liberacao, os.data_conclusao) is not null),
        'no_prazo', count(*) filter (where os.status = 'concluida' and os.previsao_retorno is not null and coalesce(os.data_liberacao, os.data_conclusao) <= os.previsao_retorno::timestamptz + interval '1 day'),
        'dias_medio_atraso', round(avg(greatest(0, extract(epoch from coalesce(os.data_liberacao, os.data_conclusao) - os.previsao_retorno::timestamptz) / 86400))
                               filter (where os.status = 'concluida' and os.previsao_retorno is not null and coalesce(os.data_liberacao, os.data_conclusao) is not null), 1)) x
        from ordens_servico os join oficinas o on o.id = os.oficina_id join veiculos v on v.id = os.veiculo_id
       where os.status <> 'cancelada' and coalesce(os.data_parou, os.created_at) >= ini_ts and (p_hub is null or v.hub_id = p_hub)
       group by o.id, o.nome) s), '[]'));

  r := r || jsonb_build_object('quebras_placa', coalesce((select jsonb_agg(x) from (
      select jsonb_build_object('placa', v.placa, 'hub', h.nome, 'qtd', count(*),
               'dias_parado', round(sum(extract(epoch from coalesce(os.data_liberacao, now()) - os.data_parou) / 86400) filter (where os.data_parou is not null), 1)) x
        from ordens_servico os join veiculos v on v.id = os.veiculo_id left join hubs h on h.id = v.hub_id
       where os.tipo in ('corretiva', 'sinistro') and os.status <> 'cancelada' and coalesce(os.data_parou, os.created_at) >= ini_ts and (p_hub is null or v.hub_id = p_hub)
       group by v.placa, h.nome order by count(*) desc, v.placa limit 20) s), '[]'));

  r := r || jsonb_build_object('quebras_hub', coalesce((select jsonb_agg(x order by (x->>'qtd')::int desc) from (
      select jsonb_build_object('hub', h.nome, 'qtd', count(*), 'placas', count(distinct v.id)) x
        from ordens_servico os join veiculos v on v.id = os.veiculo_id left join hubs h on h.id = v.hub_id
       where os.tipo in ('corretiva', 'sinistro') and os.status <> 'cancelada' and coalesce(os.data_parou, os.created_at) >= ini_ts and (p_hub is null or v.hub_id = p_hub)
       group by h.nome) s), '[]'));

  r := r || jsonb_build_object('custo_veiculo', coalesce((select jsonb_agg(x) from (
      select jsonb_build_object('placa', v.placa, 'hub', h.nome, 'qtd_os', count(*), 'custo_total', coalesce(sum(os.valor_total), 0)) x
        from ordens_servico os join veiculos v on v.id = os.veiculo_id left join hubs h on h.id = v.hub_id
       where os.status <> 'cancelada' and coalesce(os.data_parou, os.created_at) >= ini_ts and (p_hub is null or v.hub_id = p_hub)
       group by v.placa, h.nome order by coalesce(sum(os.valor_total), 0) desc, v.placa limit 15) s), '[]'));

  -- checklist por dia (só dias com foto da frota esperada; mesma regra da Visão diária: só Retirada conta)
  r := r || jsonb_build_object('checklist_dias', coalesce((select jsonb_agg(jsonb_build_object('dia', d.dia, 'esperados', c.esperados, 'fizeram', c.fizeram) order by d.dia) from (
      select dia from checklist_frota_esperada_dias where dia >= ini and dia <= hoje) d
      cross join lateral (select count(*) filter (where vd.na_lista) esperados, count(*) filter (where vd.na_lista and vd.fez) fizeram
                            from checklist_visao_diaria(d.dia) vd where (p_hub is null or vd.hub_id = p_hub)) c), '[]'));

  -- anomalias (raízes) — abertas agora, reportadas e resolvidas no período, tempo médio até resolver
  r := r || jsonb_build_object('anomalias', (
    select jsonb_build_object(
      'abertas_agora', count(*) filter (where a.status in ('aberta', 'em_reparo')),
      'abertas_por_sev', jsonb_build_object(
          'critica', count(*) filter (where a.status in ('aberta', 'em_reparo') and a.severidade = 'critica'),
          'alta', count(*) filter (where a.status in ('aberta', 'em_reparo') and a.severidade = 'alta'),
          'media', count(*) filter (where a.status in ('aberta', 'em_reparo') and a.severidade = 'media'),
          'baixa', count(*) filter (where a.status in ('aberta', 'em_reparo') and a.severidade = 'baixa')),
      'reportadas_periodo', count(*) filter (where a.created_at >= ini_ts),
      'resolvidas_periodo', count(*) filter (where a.status = 'resolvida' and a.resolvida_em >= ini_ts),
      'descartadas_periodo', count(*) filter (where a.status = 'descartada' and a.resolvida_em >= ini_ts),
      'dias_medio_resolver', round(avg(extract(epoch from a.resolvida_em - a.created_at) / 86400) filter (where a.status = 'resolvida' and a.resolvida_em >= ini_ts), 1))
      from checklist_anomalias a join veiculos v on v.id = a.veiculo_id
     where a.nova and hub_liberado(v.hub_id) and (p_hub is null or v.hub_id = p_hub)));

  -- revisões preventivas
  r := r || jsonb_build_object('revisoes', (
    select jsonb_build_object(
      'vencidas', count(*) filter (where situacao_revisao(km_ref, proximo_marco, tem_plano) = 'vencida'),
      'vencendo', count(*) filter (where situacao_revisao(km_ref, proximo_marco, tem_plano) = 'vencendo'),
      'em_dia', count(*) filter (where situacao_revisao(km_ref, proximo_marco, tem_plano) = 'em_dia'),
      'sem_plano', count(*) filter (where not tem_plano))
      from v_revisoes_status s where p_hub is null or s.hub_id = p_hub));
  return r;
end $$;
grant execute on function frota.dash_manutencao(integer, uuid) to authenticated;

-- 3. "A conferir": botões Feita (data opcional, grava no histórico) / Não feita. Quem opera Manutenções, só nos hubs dele.
create or replace function frota.conferir_revisao(p_id uuid, p_feita boolean, p_data date default null, p_obs text default null)
returns text language plpgsql security definer set search_path = frota as $$
declare c record; v_nome text;
begin
  if not (meu_papel() = 'admin' or tenho_modulo('manutencao')) then
    raise exception 'Sem permissão para conferir revisões.';
  end if;
  select * into c from revisoes_a_conferir where id = p_id for update;
  if c.id is null then raise exception 'Item não encontrado.'; end if;
  if not veiculo_liberado(c.veiculo_id) then raise exception 'Veículo fora dos seus hubs.'; end if;
  if c.status <> 'a_conferir' then raise exception 'Este marco já foi conferido.'; end if;
  if p_data is not null and p_data > (now() at time zone 'America/Sao_Paulo')::date then
    raise exception 'A data da revisão não pode ser no futuro.';
  end if;
  select nome into v_nome from usuarios_perfil where user_id = auth.uid();
  update revisoes_a_conferir
     set status = case when p_feita then 'feita' else 'nao_feita' end,
         conferido_em = now(), conferido_por = auth.uid(), conferido_obs = nullif(trim(p_obs), '')
   where id = p_id;
  if p_feita then
    insert into revisoes_preventivas (veiculo_id, marco_km, data_revisao, origem, observacao)
    values (c.veiculo_id, c.marco_km, p_data, 'manual',
            'Conferido por ' || coalesce(v_nome, 'usuário') || ' (lista "a conferir"; planilha: ' || coalesce(c.anotacao, c.motivo) || ')'
            || coalesce(' — ' || nullif(trim(p_obs), ''), ''))
    on conflict (veiculo_id, marco_km) where marco_km is not null do nothing;
  end if;
  return case when p_feita then 'feita' else 'nao_feita' end;
end $$;
revoke all on function frota.conferir_revisao(uuid, boolean, date, text) from public, anon;
grant execute on function frota.conferir_revisao(uuid, boolean, date, text) to authenticated;

-- primeira foto (dia da implantação)
select frota.gerar_status_diario();
