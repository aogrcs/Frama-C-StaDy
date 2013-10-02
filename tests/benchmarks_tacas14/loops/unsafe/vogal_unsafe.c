
/*@ requires \valid(string_entrada+(0..(MAX-1)));
  @ requires 0 <= MAX <= 3;
  @*/
void f(int MAX, char *string_entrada)
{
  char vetor_vogais[]={'a','A','e','E','i','I','o','O','u','U','\0'};
  unsigned int  i,j,cont, tam_string, n_caracter;

  string_entrada[MAX-1]='\0';
  
  n_caracter = 0;
  while(string_entrada[n_caracter]!='\0')
    n_caracter++;

  cont = 0;
  for(i=0;i<n_caracter;i++)
     for(j=0;j<8;j++)
        if(string_entrada[i] == vetor_vogais[j])
           cont++;
           
  i=0;
  int cont_aux = 0;
  while(string_entrada[i]!='\0')
  {
    for(j=0;j<10;j++)
    {
        if(string_entrada[i] == vetor_vogais[j])
           cont_aux++;
    }       
    i++;       
  }    
  //@ assert(cont_aux==cont);                          
}
