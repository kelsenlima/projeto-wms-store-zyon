CREATE FUNCTION FC_092_REMOVE_ACENTOS (@TEXTO VARCHAR (5000))RETURNS VARCHAR (5000)  AS
BEGIN
     DECLARE @COMACENTOS VARCHAR(50),
             @SEMACENTOS VARCHAR (50),
             @QTD_TEXTO INT,
             @CONTADOR INT,
             @QTD INT,
             @CONT INT,
             @CONT_C INT,
             @LETRA_T VARCHAR(1),
             @LETRA_C VARCHAR(1),
             @RESULTADO VARCHAR (5000),
             @TEXTE VARCHAR (30)

             SET @COMACENTOS = "¿¬ ‘Œ€√’¡…Õ”⁄«‹áÉ"
             SET @SEMACENTOS =  "AAEOIUAOAEIOUCU  "
             SET @QTD_TEXTO = (SELECT LEN(@TEXTO))
             SET @CONTADOR = 0
             SET @RESULTADO = 
             INICIO:
             WHILE @CONTADOR < @QTD_TEXTO
               
                  BEGIN
                       SET @CONTADOR = @CONTADOR+1
                       SET @LETRA_T = (SELECT SUBSTRING(@TEXTO,@CONTADOR,1))
                       SET @CONT = (SELECT LEN(@COMACENTOS))  
                       SET @QTD = 0
                             
                       WHILE @QTD < @CONT
                             BEGIN
                                  SET @QTD = @QTD + 1
                                  SET @LETRA_C = (SELECT SUBSTRING(@COMACENTOS,@QTD,1)) 
                                  IF @LETRA_C = @LETRA_T 
                                     BEGIN
                                           SET @RESULTADO = @RESULTADO + (SELECT SUBSTRING(@SEMACENTOS,@QTD,1))
                                           GOTO INICIO
                                     END
                                  ELSE
                                      BEGIN  
                                           IF @QTD = @CONT 
                                           SET @RESULTADO =  @RESULTADO + @LETRA_T                                                         
                                      END
                             END 
                                   
                  END
                  RETURN  @RESULTADO
END
