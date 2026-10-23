-- =============================================================================
-- C1: "foto inicial" das OS em aberto no histórico de status (INSERT de dado real).
-- SÓ RODAR COM APROVAÇÃO DO JEFFERSON.
-- Por quê: o gatilho registra trocas a partir de agora; as OS já abertas ficariam sem
-- ponto de partida. Grava 1 linha por OS aberta (sem concluída/cancelada) com o status
-- atual, marcada origem = 'implantacao' — ou seja, "estava neste status quando o
-- histórico começou", não a data real em que entrou nele.
-- Idempotente: não grava de novo para OS que já têm linha de status.
-- Em 23/10/2026: 16 OS (15 aguardando_agendamento, 1 aguardando_orcamento).
-- =============================================================================
insert into frota.os_status_historico (os_id, campo, valor_anterior, valor_novo, mudou_em, origem)
select o.id, 'status', null, o.status::text, now(), 'implantacao'
from frota.ordens_servico o
where o.status not in ('concluida', 'cancelada')
  and not exists (select 1 from frota.os_status_historico h where h.os_id = o.id and h.campo = 'status');
