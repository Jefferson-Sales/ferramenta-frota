// Regras de cálculo do front-end, compartilhadas pelo index.html e pelo checklist.html.
// Só funções puras (sem tela, sem banco), para poderem ser testadas em testes/regras.test.html.
// Regras que ficam no banco (km excedente, status do contrato, resultado do checklist)
// são testadas em testes/regras.test.sql.
(function (global) {
  "use strict";

  var OS_FECHADAS = ["concluida", "cancelada"];
  var PONTOS_POR_GRAU = { leve: 3, media: 4, grave: 5, gravissima: 7 };

  // Qualidade da Frota: status do veículo = pior anomalia aberta agora.
  // crítica → urgente; alta → reparo; média/baixa → atencao; nenhuma → ok; nunca teve checklist → sem.
  function statusQualidade(criticas, altas, total, temChecklist) {
    if (criticas > 0) return "urgente";
    if (altas > 0) return "reparo";
    if (total > 0) return "atencao";
    return temChecklist ? "ok" : "sem";
  }

  // Franquia de km (contrato pool): cor da faixa pelo % utilizado.
  // < 85% verde; de 85% até menos de 100% amarelo; 100% ou mais vermelho; sem dado neutro.
  function faixaFranquia(pct) {
    if (pct == null) return "neutral";
    if (pct >= 100) return "crit";
    if (pct >= 85) return "warn";
    return "good";
  }

  // OS vencida: tem previsão de retorno no passado e ainda está aberta.
  // OS só "agendada" (carro ainda não parou) e OS concluída/cancelada não contam.
  function osVencida(os, agora) {
    return !!(os.previsao_retorno && os.status !== "agendada" && OS_FECHADAS.indexOf(os.status) === -1 &&
              new Date(os.previsao_retorno) < agora);
  }

  // Checklist: km informado menor que o maior km conhecido (último checklist ou cadastro).
  // Devolve o km de referência quando deve avisar, ou 0 quando está tudo certo / não dá para comparar.
  function kmAbaixoDoUltimo(kmInformado, kmUltimoChecklist, kmCadastro) {
    var km = Number(kmInformado);
    if (!(km > 0)) return 0;
    var ref = Math.max(Number(kmUltimoChecklist) || 0, Number(kmCadastro) || 0);
    return ref && km < ref ? ref : 0;
  }

  // Revisão preventiva por km (mesma regra da função frota.situacao_revisao no banco):
  // próximo marco = último marco feito + 10.000 (sem histórico: 10.000).
  // vencida quando o km chega no marco; vencendo a partir de 1.000 km antes; modelo sem plano de itens → "sem_plano".
  function proximoMarco(ultimoMarco) {
    return (Number(ultimoMarco) || 0) + 10000;
  }
  function situacaoRevisao(km, proximo, temPlano) {
    if (!temPlano) return "sem_plano";
    km = Number(km) || 0;
    if (km >= proximo) return "vencida";
    if (km >= proximo - 1000) return "vencendo";
    return "em_dia";
  }

  // Visão Executiva (Diretoria): Admin ativo, ou Visualizador ativo com a permissão "executivo".
  // Operador nunca (decisão do Jefferson, 23/10/2026: tela só de consulta da Diretoria).
  // A mesma trava existe na Edge Function `usuarios` (não deixa gravar "executivo" para operador).
  function podeVerExecutivo(perfil) {
    if (!perfil || perfil.ativo === false) return false;
    if (perfil.papel === "admin") return true;
    return perfil.papel === "visualizador" && (perfil.modulos_visualizacao || []).indexOf("executivo") > -1;
  }

  // Status de liberação da OS (decisão do Jefferson, 23/10/2026). Mesmos valores da
  // constraint os_status_liberacao_valido no banco; OS concluída vira "liberado" (gatilho).
  var STATUS_LIBERACAO = {
    aguardando_orcamento: "Aguardando orçamento/aprovação",
    em_reparo: "Em reparo",
    pronto_retirada: "Pronto, aguardando retirada",
    liberado: "Liberado"
  };

  // Tempo em texto curto, para "há quanto tempo está neste status".
  // < 1 min → "menos de 1 min"; < 1 h → "40 min"; < 1 dia → "5 h" ou "5 h 20 min"; a partir de 1 dia → "2 d" ou "2 d 3 h".
  // Vazio, inválido ou negativo → "—".
  function duracaoTexto(ms) {
    ms = Number(ms);
    if (ms === null || isNaN(ms) || ms < 0) return "—";
    var min = Math.floor(ms / 60000);
    if (min < 1) return "menos de 1 min";
    if (min < 60) return min + " min";
    var h = Math.floor(min / 60), m = min % 60;
    if (h < 24) return h + " h" + (m ? " " + m + " min" : "");
    var d = Math.floor(h / 24), hr = h % 24;
    return d + " d" + (hr ? " " + hr + " h" : "");
  }

  // Disponibilidade da frota (Dash de Manutenção e Visão Executiva): cor pela % disponível.
  // ≥ 90% verde; ≥ 80% amarelo; abaixo vermelho; sem dado neutro.
  function faixaDisponibilidade(pct) {
    if (pct == null || isNaN(pct)) return "neutral";
    if (pct >= 90) return "good";
    if (pct >= 80) return "warn";
    return "crit";
  }

  global.Regras = {
    faixaDisponibilidade: faixaDisponibilidade,
    STATUS_LIBERACAO: STATUS_LIBERACAO,
    duracaoTexto: duracaoTexto,
    podeVerExecutivo: podeVerExecutivo,
    OS_FECHADAS: OS_FECHADAS,
    PONTOS_POR_GRAU: PONTOS_POR_GRAU,
    statusQualidade: statusQualidade,
    faixaFranquia: faixaFranquia,
    osVencida: osVencida,
    kmAbaixoDoUltimo: kmAbaixoDoUltimo,
    proximoMarco: proximoMarco,
    situacaoRevisao: situacaoRevisao
  };
})(typeof window !== "undefined" ? window : globalThis);
