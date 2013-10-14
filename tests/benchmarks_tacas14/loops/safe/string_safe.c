
/*@ requires MAX == 5;
  @ requires \valid(string_A+(0..MAX-1));
  @ requires \valid(string_B+(0..MAX-1));
  @ requires
  \forall int x; 0 <= x < MAX ==> (string_B[x] == '\0' ==> string_A[x] == '\0');
  @*/
void f(int MAX, char* string_A, char* string_B)
{
  int i, j, nc_A, nc_B, found=0;  
  
  
  string_A[MAX-1]='\0';
  string_B[MAX-1]='\0';

  nc_A = 0;
  /*@ loop invariant 0 <= nc_A <= MAX;
    @ loop variant MAX-nc_A;
    @*/
  while(string_A[nc_A]!='\0')
    nc_A++;

  nc_B = 0;
  /*@ loop invariant 0 <= nc_B <= MAX;
    @ loop variant MAX-nc_B;
    @*/
  while(string_B[nc_B]!='\0')
    nc_B++;

  
  
  i=j=0;
  /*@ loop invariant 0 <= i <= MAX;
    @ loop invariant 0 <= j <= MAX;
    @ loop invariant j <= i;
    @*/
  while((i<nc_A) && (j<nc_B))
  {
    if(string_A[i] == string_B[j]) 
    {
       i++;
       j++;
    }   
    else
    {
       i = i-j+1;
       j = 0;
    }   
  } 

  found = (j>nc_B-1);
  
  //@ assert(found == 0 || found == 1);
}
