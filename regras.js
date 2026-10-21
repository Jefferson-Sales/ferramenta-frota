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

  global.Regras = {
    OS_FECHADAS: OS_FECHADAS,
    PONTOS_POR_GRAU: PONTOS_POR_GRAU,
    statusQualidade: statusQualidade,
    faixaFranquia: faixaFranquia,
    osVencida: osVencida,
    kmAbaixoDoUltimo: kmAbaixoDoUltimo
  };
})(typeof window !== "undefined" ? window : globalThis);
