SELECT PRO.CODIGOEMPRESA,
       EMP.DESCRICAOEMPRESA,
       PRO.CODIGOPRODUTO,
       PRO.DESCRICAOPRODUTO,
       TUC.TIPOUC,
       TUC.FATORTIPOUC,
       PRO.CODIGOGRUPO,
       (SELECT GRU.DESCRICAOGRUPO
          FROM GRUPO GRU
         WHERE GRU.CODIGOEMPRESA = PRO.CODIGOEMPRESA
           AND GRU.CODIGOGRUPO = PRO.CODIGOGRUPO) AS DESCRICAOGRUPO,
       PRO.CODIGOSUBGRUPO,
       (SELECT SGRU.DESCRICAOSUBGRUPO
          FROM SUBGRUPO SGRU
         WHERE SGRU.CODIGOSUBGRUPO = PRO.CODIGOSUBGRUPO) AS DESCRICAOSUBGRUPO,
       PRO.CODIGOCATEGORIA,
       (SELECT CAT.DESCRICAOCATEGORIA
          FROM CATEGORIA CAT
         WHERE CAT.CODIGOCATEGORIA = PRO.CODIGOCATEGORIA) AS DESCRICAOCATEGORIA,
       PRO.CODIGOPUBLICOALVO,
       (SELECT PUB.DESCRICAOPUBLICOALVO
          FROM PUBLICOALVO PUB
         WHERE PUB.CODIGOPUBLICOALVO = PRO.CODIGOPUBLICOALVO) AS DESCRICAOPUBLICOALVO
  FROM PRODUTO PRO,
       EMPRESA EMP,
       TIPOUC TUC
 WHERE PRO.CODIGOEMPRESA = EMP.CODIGOEMPRESA
   AND PRO.CODIGOEMPRESA = TUC.CODIGOEMPRESA(+)
   AND PRO.CODIGOPRODUTO = TUC.CODIGOPRODUTO(+)
   AND PRO.CODIGOEMPRESA = '53162095002400'
   AND NOT EXISTS ( SELECT TUC.TIPOUC FROM TIPOUC TUC WHERE TUC.CODIGOEMPRESA = PRO.CODIGOEMPRESA
                    AND TUC.CODIGOPRODUTO = PRO.CODIGOPRODUTO
                    AND TUC.TIPOUC = 'CX')
