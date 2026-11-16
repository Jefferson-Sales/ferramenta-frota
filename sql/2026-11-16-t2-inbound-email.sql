-- T2 (16/11/2026): recebimento de NF/boleto por e-mail (frota@) direto na Triagem de notas.
-- Pedido do Jefferson: cruzar o REMETENTE com fornecedores; guardar só PDF; vencimento em branco (conferido na tela/OCR depois).
--
-- 1) Chave do webhook no Vault (gerada aqui, nunca escrita no código nem no chat). A Edge Function
--    inbound-triagem-nfs confere com frota.verificar_inbound_triagem (só service_role). Para ver o valor e
--    montar a URL do provedor: painel do Supabase → Vault → inbound_triagem_chave.
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'inbound_triagem_chave') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(24), 'hex'), 'inbound_triagem_chave',
      'Chave do webhook de e-mail da Triagem de notas (Edge Function inbound-triagem-nfs)');
  end if;
end $$;

create or replace function frota.verificar_inbound_triagem(chave text)
returns boolean language sql stable security definer set search_path = vault, pg_temp as $$
  select coalesce(length(chave), 0) >= 32 and exists (
    select 1 from vault.decrypted_secrets where name = 'inbound_triagem_chave' and decrypted_secret = chave);
$$;
revoke all on function frota.verificar_inbound_triagem(text) from public, anon, authenticated;
grant execute on function frota.verificar_inbound_triagem(text) to service_role;

-- 2) Fornecedor do e-mail: CNPJ lido do XML/assunto primeiro (mais seguro); senão o e-mail do remetente igual ao
--    contato_email de UM fornecedor ativo (dois fornecedores com o mesmo e-mail = não escolhe).
create or replace function frota.triagem_achar_fornecedor(p_cnpj text, p_email text)
returns table (fornecedor_id uuid, achado_por text) language sql stable set search_path = '' as $$
  with c as (
    select f.id from frota.fornecedores f
     where p_cnpj is not null and f.cnpj = regexp_replace(p_cnpj, '\D', '', 'g') limit 1
  ), e as (
    select min(f.id::text)::uuid as id from frota.fornecedores f
     where p_email is not null and f.ativo and lower(trim(f.contato_email)) = lower(trim(p_email))
    having count(*) = 1
  )
  select id, 'cnpj' from c
  union all
  select id, 'email' from e where not exists (select 1 from c)
  limit 1;
$$;
revoke all on function frota.triagem_achar_fornecedor(text, text) from public, anon, authenticated;
grant execute on function frota.triagem_achar_fornecedor(text, text) to service_role;

alter table frota.financeiro_notas_triagem add column if not exists fornecedor_achado_por text
  check (fornecedor_achado_por in ('cnpj', 'email', 'tela'));
comment on column frota.financeiro_notas_triagem.fornecedor_achado_por is 'Como o fornecedor foi identificado: cnpj (XML/assunto), email (remetente = contato_email) ou tela.';

-- 3) Gatilho: na chegada, remetente em minúsculas e fornecedor pelo CNPJ ou e-mail
create or replace function frota.tg_triagem_notas()
 returns trigger language plpgsql set search_path to '' as $function$
declare ach record;
begin
  if tg_op = 'INSERT' then
    new.cnpj_lido := nullif(regexp_replace(coalesce(new.cnpj_lido, ''), '\D', '', 'g'), '');
    new.remetente := nullif(lower(trim(coalesce(new.remetente, ''))), '');
    if new.fornecedor_id is null then
      select * into ach from frota.triagem_achar_fornecedor(new.cnpj_lido, new.remetente);
      new.fornecedor_id := ach.fornecedor_id; new.fornecedor_achado_por := ach.achado_por;
    end if;
    new.status_aprovacao := 'pendente';
    new.justificativa_reprovacao := null; new.decidido_por := null; new.decidido_por_nome := null; new.decidido_em := null;
  else
    if new.message_id is distinct from old.message_id or new.remetente is distinct from old.remetente
       or new.data_recebimento is distinct from old.data_recebimento or new.caminho_pdf_nf is distinct from old.caminho_pdf_nf
       or new.caminho_pdf_boleto is distinct from old.caminho_pdf_boleto then
      raise exception 'Os dados do e-mail recebido não podem ser alterados.';
    end if;
    if new.fornecedor_id is distinct from old.fornecedor_id then
      new.fornecedor_achado_por := case when new.fornecedor_id is null then null else 'tela' end;
    end if;
    if new.status_aprovacao is distinct from old.status_aprovacao then
      if old.status_aprovacao <> 'pendente' and frota.meu_papel() is distinct from 'admin' then
        raise exception 'Só o admin reabre uma nota já decidida.';
      end if;
      if new.status_aprovacao = 'reprovada' and length(trim(coalesce(new.justificativa_reprovacao, ''))) < 10 then
        raise exception 'Escreva a justificativa da reprovação (mínimo 10 letras); ela vai para o fornecedor.';
      end if;
      if new.status_aprovacao = 'pendente' then
        new.justificativa_reprovacao := null; new.decidido_por := null; new.decidido_por_nome := null; new.decidido_em := null;
      else
        if new.status_aprovacao = 'aprovada' then new.justificativa_reprovacao := null; end if;
        new.justificativa_reprovacao := nullif(trim(new.justificativa_reprovacao), '');
        new.decidido_por := auth.uid(); new.decidido_por_nome := frota.nome_usuario_atual(); new.decidido_em := now();
      end if;
    elsif new.justificativa_reprovacao is distinct from old.justificativa_reprovacao
       or new.decidido_por is distinct from old.decidido_por or new.decidido_em is distinct from old.decidido_em then
      raise exception 'A decisão só muda junto com o status.';
    end if;
  end if;
  new.dias_ate_vencimento := new.data_vencimento - (new.data_recebimento at time zone 'America/Sao_Paulo')::date;
  new.status_validacao_dias := frota.prazo_triagem(new.data_recebimento, new.data_vencimento);
  return new;
end;
$function$;
