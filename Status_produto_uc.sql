select *
from loteentrada le, loteentradasequencia les
where le.codigoestabelecimento = les.codigoestabelecimento
and le.loteentrada = les.loteentrada
and le.codigoempresa = '53162095002400'
and les.quantidadeatual >0
and not exists (select 1 from tipouc tuc where tuc.codigoempresa = le.codigoempresa 
                                           and tuc.codigoproduto = le.codigoproduto
                                           and tuc.tipouc like '%CX%'
                                           and tuc.volumeexpedicao = 1)
