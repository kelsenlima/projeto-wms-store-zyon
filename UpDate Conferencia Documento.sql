UPDATE ENDERECO E
   SET E.ESPECIEENDERECO=
 WHERE E.ETIQUETAENDERECO IN (SELECT TEXTO FROM TEXTO1)‏


‎update produto p set p.especieressuprimento=3 where p.codigoempresa='53162095002400'‏


‎-- Update para ajuste de conferência de documentos pedido para os documentos nota (depois do faturamento).‏
 begin
   for cConf in (select distinct c.codigodocumento, dsnf.codigodocumento coddocnf, dsnf.documentosaida
                  from conferencia c, documentosaida ds, documentosaida dsnf
                where c.codigoestabelecimento=ds.codigoestabelecimento
                  and c.codigodocumento=ds.codigodocumento
                  and c.estadoconferencia =5
                  and ds.estadodocumento=29
                  and ds.tipodocumento='PED'
                  and ds.codigoestabelecimento=1
                  and ds.codigodepositante='53162095002400'
                  and dsnf.codigoestabelecimento=ds.codigoestabelecimento
                  and dsnf.codigoempresa=ds.codigoempresa
                  and dsnf.tipodocumento='NF'
                  and dsnf.documentoqualidade=ds.documentosaida
                  and dsnf.estadodocumento=23) loop
       UPDATE CONFERENCIA C
          SET C.CODIGODOCUMENTO=cConf.Coddocnf
        WHERE C.CODIGOESTABELECIMENTO=1
          AND C.CODIGODOCUMENTO=cConf.Codigodocumento
          AND C.ESTADOCONFERENCIA=5;
    end loop;
end;
