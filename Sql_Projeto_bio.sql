update produto p set p.idproduto = 'VN' where p.codigoempresa = '53162095002400' and p.codigoproduto = '1000098'
update produto p set p.utilizarembalagemexped = 0 where p.codigoempresa = '53162095002400'
update produto p set p.utilizarembalagemexpedconf = 1 where p.codigoempresa = '53162095002400'
update produto p set p.codigoetiqueta = 4 where p.codigoempresa = '53162095002400'
update documentosaida ds set ds.tipodocumento = 'SUB' where ds.documentosaida = '81093383' and ds.tipodocumento = 'PED'
update produto p set p.especieressuprimento=3 where p.codigoempresa='53162095002400'‏


select * from texto1 for update
truncate table texto1

select * from texto1 t1, endereco e
where e.etiquetaendereco (+)= t1.texto
  and e.codigoestabelecimento is null
  
UPDATE ENDERECO E
   SET E.ESPECIEENDERECO=17
 WHERE E.ETIQUETAENDERECO IN (SELECT TEXTO FROM TEXTO1)


select p.codigoproduto, p.idproduto
from produto p
where p.codigoempresa = '53162095002400'
--and p.codigoproduto = '1000091'
order by p.codigoproduto

select * from empresa e
where e.depositante = 1

select distinct ls.codigomatriz,
       ls.documentosaida,
       ls.codigoproduto,
       sum(ls.quantidadedocumento),
       (select tu.tipouc from tipouc tu where tu.codigoproduto = ls.codigoproduto and tu.tipouc = 'CX') as TIPOUC            
from lotesaida ls
where ls.codigoestabelecimento = 1
and ls.codigomatriz = '53162095002400'
and ls.tipodocumento = 'PED'
and ls.documentosaida = '81093336'
--and ls.lotesaida = 291683
group by ls.codigomatriz,
       ls.documentosaida,
       ls.codigoproduto,
       tipouc
      
select * from ediregistro e
where e.dado002 = '53162095002400'for update
and e.agrupardocumentoromaneio

UPDATE EDIREGISTRO SET ESTADOINTEGRACAO = 3 WHERE DADO006 = 'NUMDOC' AND TIPOINTEGRACAO = 1004

UPDATE EDIREGISTRO SET ESTADOINTEGRACAO = 3 WHERE DADO006 in ('81093288','81093289') AND TIPOINTEGRACAO = 1004
