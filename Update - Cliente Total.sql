select p.codigoempresa, p.tipobaixa, p.tipobaixasecundario, p.especieressuprimento, p.prioridadebaixa, p.utilizarembalagemexpedconf
from produto p
where p.codigoempresa = 'TOTAL'
-- and p.tipologistico = 6
and p.tipobaixa = 6 -- 1
and p.tipobaixasecundario = 1 -- 2
and p.especieressuprimento = 1 -- 3
and p.prioridadebaixa = 1
and  p.utilizarembalagemexpedconf = 1 -- 0

update produto p set p.tipobaixa = 1, p.tipobaixasecundario = 2, p.especieressuprimento = 3, p.utilizarembalagemexpedconf = 0
where p.codigoempresa = 'TOTAL'
-- and p.tipologistico = 6
and p.tipobaixa = 6 -- 1
and p.tipobaixasecundario = 1 -- 2
and p.especieressuprimento = 1 -- 3
and p.prioridadebaixa = 1
and  p.utilizarembalagemexpedconf = 1 -- 0
