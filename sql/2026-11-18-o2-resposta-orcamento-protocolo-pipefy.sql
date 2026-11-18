-- O2 (18/11/2026, pedido do Jefferson para o treinamento de 19/11):
--  1. Resposta à oficina ao aprovar/recusar um orçamento: a tela grava assunto e texto junto com a decisão; o banco
--     grava o e-mail de quem decidiu (login) e a tratativa da OS passa a ter quem respondeu (nome e e-mail) e o texto.
--     O envio é feito pela Edge Function inbound-triagem-nfs (?acao=responder_orcamento): Postmark quando houver os
--     segredos POSTMARK_SERVER_TOKEN/POSTMARK_FROM; sem eles, devolve os dados para a tela abrir o e-mail de quem
--     decidiu (mailto). Canal/hora/erro do envio só o sistema grava.
--  2. Aprovar orçamento ligado a uma OS preenche o valor da OS quando ele está vazio ou zerado (nunca sobrescreve).
--  3. Triagem financeira: "Protocolado no Pipefy" (plano B enquanto o token não tem acesso ao pipe 301583172) —
--     marca só nota aprovada; quem/quando pelo login.

alter table frota.manutencao_orcamentos_triagem
  add column decidido_por_email text,
  add column resposta_assunto text check (resposta_assunto is null or length(resposta_assunto) <= 300),
  add column resposta_texto text check (resposta_texto is null or length(resposta_texto) <= 4000),
  add column resposta_canal text check (resposta_canal in ('postmark', 'mailto')),
  add column resposta_enviada_em timestamptz,
  add column resposta_erro text;

create or replace function frota.tg_orcamentos_triagem() returns trigger
language plpgsql security definer set search_path = frota, public as $$
declare v_os record; f record;
begin
  if tg_op = 'UPDATE' then
    if (new.message_id, new.remetente, new.assunto, new.data_recebimento, new.caminho_pdf, new.origem, new.motivo_deteccao, new.cnpjs_lidos)
       is distinct from (old.message_id, old.remetente, old.assunto, old.data_recebimento, old.caminho_pdf, old.origem, old.motivo_deteccao, old.cnpjs_lidos) then
      raise exception 'Os dados do e-mail recebido não podem ser alterados.';
    end if;
    if auth.uid() is not null and (new.resposta_canal, new.resposta_enviada_em, new.resposta_erro)
       is distinct from (old.resposta_canal, old.resposta_enviada_em, old.resposta_erro) then
      raise exception 'O envio da resposta à oficina é registrado pelo sistema.';
    end if;
    if old.status <> 'pendente' and new.status = old.status and new.os_id is distinct from old.os_id then
      raise exception 'Orçamento já decidido: reabra antes de trocar a OS.';
    end if;
    if old.status <> 'pendente' and new.status = old.status
       and (new.resposta_texto, new.resposta_assunto) is distinct from (old.resposta_texto, old.resposta_assunto) then
      raise exception 'A resposta enviada à oficina não muda depois da decisão.';
    end if;
    if new.status is distinct from old.status then
      if old.status <> 'pendente' and meu_papel() is distinct from 'admin' then raise exception 'Só o admin reabre um orçamento já decidido.'; end if;
      if new.status = 'reprovado' and length(btrim(coalesce(new.motivo_reprovacao, ''))) < 5 then raise exception 'Escreva o motivo da recusa (mínimo 5 letras).'; end if;
      if new.status = 'aprovado' and new.os_id is null then raise exception 'Ligue o orçamento a uma OS antes de aprovar.'; end if;
      if new.status = 'pendente' then
        new.motivo_reprovacao := null; new.decidido_por := null; new.decidido_por_nome := null; new.decidido_em := null; new.decidido_por_email := null;
        new.resposta_assunto := null; new.resposta_texto := null; new.resposta_canal := null; new.resposta_enviada_em := null; new.resposta_erro := null;
      else
        new.decidido_por := auth.uid(); new.decidido_por_nome := nome_usuario_atual(); new.decidido_em := now();
        new.decidido_por_email := nullif(lower(btrim(coalesce(auth.jwt() ->> 'email', ''))), '');
        new.resposta_texto := nullif(btrim(coalesce(new.resposta_texto, '')), '');
        new.resposta_assunto := nullif(btrim(coalesce(new.resposta_assunto, '')), '');
      end if;
      if new.status = 'aprovado' then new.motivo_reprovacao := null; end if;
    elsif new.decidido_por_email is distinct from old.decidido_por_email then
      raise exception 'Quem decidiu é gravado pelo sistema.';
    end if;
  else
    new.status := 'pendente'; new.os_id := null; new.motivo_reprovacao := null;
    new.decidido_por := null; new.decidido_por_nome := null; new.decidido_em := null; new.decidido_por_email := null;
    new.resposta_assunto := null; new.resposta_texto := null; new.resposta_canal := null; new.resposta_enviada_em := null; new.resposta_erro := null;
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
  if new.os_id is not null and new.veiculo_id is distinct from (select o.veiculo_id from ordens_servico o where o.id = new.os_id) then
    raise exception 'A OS ligada é de outro carro: desligue a OS antes de trocar a placa.';
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

-- tratativa na OS com quem respondeu e o texto; aprovar preenche o valor da OS vazio/zerado
create or replace function frota.tg_orcamentos_triagem_tratativa() returns trigger
language plpgsql security definer set search_path = frota, public as $$
begin
  if new.os_id is not null and new.status in ('aprovado', 'reprovado') and new.status is distinct from old.status then
    insert into os_tratativas (os_id, texto) values (new.os_id, left(
      'Orçamento recebido por e-mail' || coalesce(' (' || new.remetente || ')', '')
      || coalesce(' de R$ ' || replace(replace(replace(to_char(new.valor_lido, 'FM999G999G990D00'), ',', '#'), '.', ','), '#', '.'), '')
      || case when new.status = 'aprovado' then ' APROVADO.' else ' REPROVADO: ' || btrim(new.motivo_reprovacao) end
      || coalesce(' Resposta à oficina por ' || coalesce(new.decidido_por_nome, 'usuário') || coalesce(' <' || new.decidido_por_email || '>', '')
                  || ': "' || new.resposta_texto || '"', ''), 2000));
    if new.status = 'aprovado' and coalesce(new.valor_lido, 0) > 0 then
      update ordens_servico set valor_total = new.valor_lido where id = new.os_id and coalesce(valor_total, 0) = 0;
    end if;
  end if;
  return null;
end $$;

-- dados para a Edge Function enviar a resposta (chamada com o login de quem decidiu)
create or replace function frota.orcamento_resposta_preparar(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = frota, public as $$
declare t record;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'motivo', 'Sem login.'); end if;
  select * into t from manutencao_orcamentos_triagem o where o.id = p_id
     and (meu_papel() = 'admin' or (tenho_modulo('manutencao') and (o.veiculo_id is null or veiculo_liberado(o.veiculo_id))));
  if t.id is null then return jsonb_build_object('ok', false, 'motivo', 'Orçamento não encontrado ou sem permissão.'); end if;
  if t.status = 'pendente' then return jsonb_build_object('ok', false, 'motivo', 'Decida o orçamento antes de responder.'); end if;
  if t.resposta_canal is not null then return jsonb_build_object('ok', false, 'motivo', 'A resposta já foi registrada.'); end if;
  if t.remetente is null then return jsonb_build_object('ok', false, 'motivo', 'O orçamento chegou sem remetente.'); end if;
  if t.resposta_texto is null then return jsonb_build_object('ok', false, 'motivo', 'Sem texto de resposta.'); end if;
  return jsonb_build_object('ok', true, 'para', t.remetente, 'assunto', coalesce(t.resposta_assunto, 'Re: ' || coalesce(t.assunto, 'orçamento')),
    'texto', t.resposta_texto, 'responder_para', coalesce(t.decidido_por_email, nullif(lower(auth.jwt() ->> 'email'), '')),
    'nome', coalesce(t.decidido_por_nome, nome_usuario_atual()));
end $$;
revoke all on function frota.orcamento_resposta_preparar(uuid) from public, anon;
grant execute on function frota.orcamento_resposta_preparar(uuid) to authenticated;

-- "Protocolado no Pipefy" na triagem financeira
alter table frota.financeiro_notas_triagem
  add column protocolado_pipefy_em timestamptz, add column protocolado_pipefy_por uuid, add column protocolado_pipefy_por_nome text;
create or replace function frota.tg_triagem_protocolo() returns trigger
language plpgsql set search_path = frota, public as $$
begin
  if new.protocolado_pipefy_em is distinct from old.protocolado_pipefy_em then
    if new.protocolado_pipefy_em is not null then
      if new.status_aprovacao <> 'aprovada' then raise exception 'Só nota aprovada é protocolada no Pipefy.'; end if;
      new.protocolado_pipefy_em := now(); new.protocolado_pipefy_por := auth.uid(); new.protocolado_pipefy_por_nome := nome_usuario_atual();
    else
      new.protocolado_pipefy_por := null; new.protocolado_pipefy_por_nome := null;
    end if;
  elsif (new.protocolado_pipefy_por, new.protocolado_pipefy_por_nome) is distinct from (old.protocolado_pipefy_por, old.protocolado_pipefy_por_nome) then
    raise exception 'Quem protocolou é gravado pelo sistema.';
  end if;
  if new.status_aprovacao <> 'aprovada' and new.protocolado_pipefy_em is not null then
    new.protocolado_pipefy_em := null; new.protocolado_pipefy_por := null; new.protocolado_pipefy_por_nome := null;   -- reaberta: sai do protocolo
  end if;
  return new;
end $$;
revoke all on function frota.tg_triagem_protocolo() from public, anon, authenticated;
create trigger triagem_protocolo_pipefy before update on frota.financeiro_notas_triagem
  for each row execute function frota.tg_triagem_protocolo();
