-- O1 (18/11/2026): Triagem de orçamentos em Manutenções + "Mover para…" entre as três filas de triagem
-- (pedido do Jefferson: orçamento da Oficina The para a GDT7I83 caiu na triagem financeira em 17/11).
--
--  * manutencao_orcamentos_triagem: uma linha por e-mail de orçamento; PDF no bucket privado manutencao-orcamentos
--    ({id}/orcamento.pdf), guardado como CAMINHO. Lidos do PDF/assunto (Regras.lerOrcamento na Edge Function): placa,
--    CNPJs, valor total, trecho dos serviços. O gatilho acha o veículo (só pela placa), a oficina (CNPJ em oficinas;
--    senão o fornecedor pelo CNPJ/e-mail e a oficina ligada a ele) e sugere a OS aberta mais recente do carro.
--  * status pendente → aprovado (exige OS ligada) | reprovado (motivo ≥ 5 letras); quem/quando pelo login; só admin
--    reabre. Ao aprovar/reprovar, uma tratativa entra na OS (fica no histórico da OS, com o autor do login).
--    Ligar a OS de outro carro é recusado; ligar OS com o carro vazio preenche o carro.
--  * acesso (igual a Manutenções, com hub): vê quem vê Manutenções no hub do carro; decide quem opera Manutenções no
--    hub. Orçamento ainda sem carro identificado: qualquer um que vê/opera Manutenções. Ninguém cria nem apaga pela tela.
--  * triagem_movimentacoes: registro imutável de cada "Mover para…" (de qual fila/id, para qual, quem, quando, motivo).
--    O item sai da fila de origem (linha e arquivos) e entra pendente na de destino com os mesmos PDFs — quem move é a
--    Edge Function (service_role) depois de triagem_mover_autorizacao conferir o login: só item pendente, e só quem
--    opera a fila de origem.

create table frota.manutencao_orcamentos_triagem (
  id uuid primary key default gen_random_uuid(),
  message_id text unique,
  origem text not null default 'email' check (origem in ('email', 'movida')),
  remetente text, assunto text,
  data_recebimento timestamptz not null default now(),
  motivo_deteccao text,
  caminho_pdf text, outros_anexos int not null default 0,
  placa_lida text, veiculo_id uuid references frota.veiculos(id),
  cnpjs_lidos text[] not null default '{}', cnpj_lido text,
  oficina_id uuid references frota.oficinas(id), oficina_achada_por text,
  valor_lido numeric(12,2), descricao_lida text,
  os_sugerida_id uuid references frota.ordens_servico(id) on delete set null,
  os_id uuid references frota.ordens_servico(id) on delete set null,
  status text not null default 'pendente' check (status in ('pendente', 'aprovado', 'reprovado')),
  motivo_reprovacao text,
  decidido_por uuid, decidido_por_nome text, decidido_em timestamptz,
  criado_em timestamptz not null default now()
);
create index manutencao_orcamentos_triagem_status on frota.manutencao_orcamentos_triagem (status, data_recebimento desc);
create index manutencao_orcamentos_triagem_os on frota.manutencao_orcamentos_triagem (os_id);
alter table frota.manutencao_orcamentos_triagem enable row level security;
create policy ver_orcamentos_triagem on frota.manutencao_orcamentos_triagem for select to authenticated
  using (frota.meu_papel() = 'admin' or (frota.posso_ver('manutencao') and (veiculo_id is null or frota.veiculo_liberado(veiculo_id))));
create policy decidir_orcamentos_triagem on frota.manutencao_orcamentos_triagem for update to authenticated
  using (frota.meu_papel() = 'admin' or (frota.tenho_modulo('manutencao') and (veiculo_id is null or frota.veiculo_liberado(veiculo_id))))
  with check (frota.meu_papel() = 'admin' or (frota.tenho_modulo('manutencao') and (veiculo_id is null or frota.veiculo_liberado(veiculo_id))));
grant select, update on frota.manutencao_orcamentos_triagem to authenticated;
comment on table frota.manutencao_orcamentos_triagem is 'Fila de orçamentos de oficina recebidos por e-mail (Triagem de orçamentos). Criada só pela Edge Function inbound-triagem-nfs.';

create or replace function frota.tg_orcamentos_triagem() returns trigger
language plpgsql security definer set search_path = frota, public as $$
declare v_os record; f record;
begin
  if tg_op = 'UPDATE' then
    if (new.message_id, new.remetente, new.assunto, new.data_recebimento, new.caminho_pdf, new.origem, new.motivo_deteccao, new.cnpjs_lidos)
       is distinct from (old.message_id, old.remetente, old.assunto, old.data_recebimento, old.caminho_pdf, old.origem, old.motivo_deteccao, old.cnpjs_lidos) then
      raise exception 'Os dados do e-mail recebido não podem ser alterados.';
    end if;
    if old.status <> 'pendente' and new.status = old.status and new.os_id is distinct from old.os_id then
      raise exception 'Orçamento já decidido: reabra antes de trocar a OS.';
    end if;
    if new.status is distinct from old.status then
      if old.status <> 'pendente' and meu_papel() is distinct from 'admin' then raise exception 'Só o admin reabre um orçamento já decidido.'; end if;
      if new.status = 'reprovado' and length(btrim(coalesce(new.motivo_reprovacao, ''))) < 5 then raise exception 'Escreva o motivo da reprovação (mínimo 5 letras).'; end if;
      if new.status = 'aprovado' and new.os_id is null then raise exception 'Ligue o orçamento a uma OS antes de aprovar.'; end if;
      if new.status = 'pendente' then new.motivo_reprovacao := null; new.decidido_por := null; new.decidido_por_nome := null; new.decidido_em := null;
      else new.decidido_por := auth.uid(); new.decidido_por_nome := nome_usuario_atual(); new.decidido_em := now(); end if;
      if new.status = 'aprovado' then new.motivo_reprovacao := null; end if;
    end if;
  else
    new.status := 'pendente'; new.os_id := null; new.motivo_reprovacao := null;
    new.decidido_por := null; new.decidido_por_nome := null; new.decidido_em := null;
    new.cnpjs_lidos := coalesce(new.cnpjs_lidos, '{}');
  end if;

  -- carro: pela placa; ou pela OS ligada quando o carro está vazio
  new.placa_lida := nullif(upper(regexp_replace(coalesce(new.placa_lida, ''), '[^A-Za-z0-9]', '', 'g')), '');
  if tg_op = 'INSERT' or new.placa_lida is distinct from old.placa_lida then
    new.veiculo_id := (select v.id from veiculos v where v.placa = new.placa_lida);
  end if;
  if new.os_id is not null and (tg_op = 'INSERT' or new.os_id is distinct from old.os_id) then
    select o.id, o.veiculo_id into v_os from ordens_servico o where o.id = new.os_id;
    if v_os.id is null then raise exception 'OS não encontrada.'; end if;
    if auth.uid() is not null and not os_liberada(new.os_id) then raise exception 'Você não tem acesso a essa OS.'; end if;
    if new.veiculo_id is null then
      new.veiculo_id := v_os.veiculo_id;
      new.placa_lida := (select v.placa from veiculos v where v.id = v_os.veiculo_id);
    elsif new.veiculo_id <> v_os.veiculo_id then
      raise exception 'A OS escolhida é de outro carro.';
    end if;
  end if;

  -- OS sugerida: a aberta mais recente do carro
  if tg_op = 'INSERT' or new.veiculo_id is distinct from old.veiculo_id then
    new.os_sugerida_id := (select o.id from ordens_servico o where o.veiculo_id = new.veiculo_id
                             and o.status::text not in ('concluida', 'cancelada') order by o.created_at desc limit 1);
  end if;

  -- oficina: CNPJ em oficinas; senão o fornecedor (CNPJ ou e-mail aprendido) e a oficina ligada a ele
  if tg_op = 'INSERT' then
    select o.id, o.cnpj into f from oficinas o where o.cnpj is not null and o.cnpj = any(new.cnpjs_lidos) limit 1;
    if f.id is not null then
      new.oficina_id := f.id; new.cnpj_lido := f.cnpj; new.oficina_achada_por := 'cnpj';
    else
      new.cnpj_lido := new.cnpjs_lidos[1];
      select o.id, a.achado_por into f
        from triagem_achar_fornecedor(new.cnpj_lido, new.remetente) a join oficinas o on o.fornecedor_id = a.fornecedor_id limit 1;
      if f.id is not null then new.oficina_id := f.id; new.oficina_achada_por := 'fornecedor_' || f.achado_por; end if;
    end if;
  elsif new.oficina_id is distinct from old.oficina_id then
    new.oficina_achada_por := case when new.oficina_id is null then null else 'tela' end;
  end if;
  return new;
end $$;
revoke all on function frota.tg_orcamentos_triagem() from public, anon, authenticated;
create trigger orcamentos_triagem_regras before insert or update on frota.manutencao_orcamentos_triagem
  for each row execute function frota.tg_orcamentos_triagem();

-- aprovar/reprovar deixa uma tratativa na OS (autor = login, pelo gatilho da própria tratativa)
create or replace function frota.tg_orcamentos_triagem_tratativa() returns trigger
language plpgsql security definer set search_path = frota, public as $$
begin
  if new.os_id is not null and new.status in ('aprovado', 'reprovado') and new.status is distinct from old.status then
    insert into os_tratativas (os_id, texto) values (new.os_id,
      'Orçamento recebido por e-mail' || coalesce(' (' || new.remetente || ')', '')
      || coalesce(' de R$ ' || replace(replace(replace(to_char(new.valor_lido, 'FM999G999G990D00'), ',', '#'), '.', ','), '#', '.'), '')
      || case when new.status = 'aprovado' then ' APROVADO.' else ' REPROVADO: ' || btrim(new.motivo_reprovacao) end);
  end if;
  return null;
end $$;
revoke all on function frota.tg_orcamentos_triagem_tratativa() from public, anon, authenticated;
create trigger orcamentos_triagem_tratativa after update of status on frota.manutencao_orcamentos_triagem
  for each row execute function frota.tg_orcamentos_triagem_tratativa();

-- bucket privado dos PDFs de orçamento
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('manutencao-orcamentos', 'manutencao-orcamentos', false, 10485760, array['application/pdf'])
on conflict (id) do nothing;
create or replace function frota.orcamento_triagem_liberado(p_id text) returns boolean
language sql stable security definer set search_path = frota, public as $$
  select exists (select 1 from manutencao_orcamentos_triagem o
                  where o.id::text = p_id
                    and (meu_papel() = 'admin' or (posso_ver('manutencao') and (o.veiculo_id is null or veiculo_liberado(o.veiculo_id)))));
$$;
revoke all on function frota.orcamento_triagem_liberado(text) from public, anon;
grant execute on function frota.orcamento_triagem_liberado(text) to authenticated;
create policy "manutencao_orcamentos_ler" on storage.objects for select to authenticated
  using (bucket_id = 'manutencao-orcamentos' and frota.orcamento_triagem_liberado(split_part(name, '/', 1)));

-- multas_triagem passa a aceitar item movido de outra fila
alter table frota.multas_triagem drop constraint multas_triagem_origem_check;
alter table frota.multas_triagem add constraint multas_triagem_origem_check check (origem in ('email', 'triagem_financeira', 'movida'));

-- registro imutável do "Mover para…"
create table frota.triagem_movimentacoes (
  id uuid primary key default gen_random_uuid(),
  de_fila text not null check (de_fila in ('financeiro', 'orcamentos', 'multas')),
  de_id uuid not null,
  para_fila text not null check (para_fila in ('financeiro', 'orcamentos', 'multas')),
  para_id uuid not null,
  message_id text, remetente text, assunto text, pdfs int not null default 0,
  motivo text,
  movido_por uuid, movido_por_nome text,
  movido_em timestamptz not null default now(),
  check (de_fila <> para_fila)
);
alter table frota.triagem_movimentacoes enable row level security;
create policy ver_triagem_movimentacoes on frota.triagem_movimentacoes for select to authenticated
  using (frota.meu_papel() = 'admin' or frota.tenho_modulo('financeiro') or frota.tenho_modulo('multas') or frota.tenho_modulo('manutencao'));
grant select on frota.triagem_movimentacoes to authenticated;
create trigger triagem_movimentacoes_imutavel before update or delete on frota.triagem_movimentacoes
  for each row execute function frota.tg_historico_imutavel();
comment on table frota.triagem_movimentacoes is 'Cada item movido entre as filas de triagem (financeira, orçamentos, multas). Gravada só pela Edge Function.';

-- autorização do "Mover para…" (chamada pela Edge Function com o login de quem clicou)
create or replace function frota.triagem_mover_autorizacao(p_fila text, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = frota, public as $$
declare adm boolean := meu_papel() = 'admin'; ok boolean;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'motivo', 'Sem login.'); end if;
  ok := case p_fila
    when 'financeiro' then (adm or tenho_modulo('financeiro'))
         and exists (select 1 from financeiro_notas_triagem t where t.id = p_id and t.status_aprovacao = 'pendente')
    when 'multas' then (adm or tenho_modulo('multas'))
         and exists (select 1 from multas_triagem t where t.id = p_id and t.status = 'pendente')
    when 'orcamentos' then exists (select 1 from manutencao_orcamentos_triagem t where t.id = p_id and t.status = 'pendente'
         and (adm or (tenho_modulo('manutencao') and (t.veiculo_id is null or veiculo_liberado(t.veiculo_id)))))
    else false end;
  if not coalesce(ok, false) then return jsonb_build_object('ok', false, 'motivo', 'Só quem opera esta fila move um item pendente.'); end if;
  return jsonb_build_object('ok', true, 'uid', auth.uid(), 'nome', nome_usuario_atual());
end $$;
revoke all on function frota.triagem_mover_autorizacao(text, uuid) from public, anon;
grant execute on function frota.triagem_mover_autorizacao(text, uuid) to authenticated;
