
int INFINITY = 899;

  int Source[20] = {0,4,1,1,0,0,1,3,4,4,2,2,3,0,0,3,1,2,2,3};
  int Dest[20] = {1,3,4,1,1,4,3,4,3,0,0,0,0,2,3,0,2,1,0,4};
  int Weight[20] = {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19};
  int distance[5];

/*@ requires 0 <= nodecount < 5;
  @ requires 0 <= edgecount < 20;
  @*/
void f(int nodecount, int edgecount){
  int source = 0;
  int x,y;
  int i,j;
  
  for(i = 0; i < nodecount; i++){
    if(i == source){
      distance[i] = 0;
    }
    else {
      distance[i] = INFINITY;
    }
  }

  for(i = 0; i < nodecount; i++)
    {
      for(j = 0; j < edgecount; j++)
	{
	  x = Dest[j];
	  y = Source[j];
	  if(distance[x] > distance[y] + Weight[j])
	    {
	      distance[x] = -1;
	    }
	}
    }
  for(i = 0; i < edgecount; i++)
    {
      x = Dest[i];
      y = Source[i];
      if(distance[x] > distance[y] + Weight[i])
	{
	  return;
	}
    }

 
  //@ assert \forall int i; 0 <= i < nodecount ==> distance[i]>=0;

}

