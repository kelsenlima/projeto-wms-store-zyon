SELECT DOS.CODIGODEPOSITANTE,
       DOS.NFEESTADO,
       NES.DESCRICAOESTADO,
       DOS.ESTADODOCUMENTO,
       ED.DESCRICAOESTADODOCUMENTO
  FROM DOCUMENTOOFICIALSAIDA DOS,
       ESTADODOCUMENTO ED,
       NFEESTADO NES       
 WHERE DOS.CODIGOESTABELECIMENTO = 1
   -- AND DOS.NFEESTADO = 656 -- Consumo Indevido
   AND DOS.NFEESTADO <> 100
   AND DOS.NFEESTADO <> 101
   --AND DOS.NFEESTADO = 27
   AND DOS.DATAEMISSAO >= '01/01/2016'
   AND DOS.ESTADODOCUMENTO = ED.ESTADODOCUMENTO
   AND DOS.NFEESTADO = NES.NFEESTADO
   AND DOS.ESTADODOCUMENTO = 37

SELECT COUNT(*) 
  FROM DOCUMENTOOFICIALSAIDA DOS,
       ESTADODOCUMENTO ED,
       NFEESTADO NES       
 WHERE DOS.CODIGOESTABELECIMENTO = 1
   -- AND DOS.NFEESTADO = 656 -- Consumo Indevido
   AND DOS.NFEESTADO <> 100
   AND DOS.NFEESTADO <> 101
   --AND DOS.NFEESTADO = 27
   AND DOS.ESTADODOCUMENTO = ED.ESTADODOCUMENTO
   AND DOS.NFEESTADO = NES.NFEESTADO
   AND DOS.ESTADODOCUMENTO = 37 

UPDATE DOCUMENTOOFICIALSAIDA DOS SET DOS.NFEESTADO = 1
 WHERE DOS.CODIGOESTABELECIMENTO = 1
   AND DOS.NFEESTADO = ?
   AND DOS.ESTADODOCUMENTO = 37

