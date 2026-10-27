// Auth-free fixture executable. Mode comes only from its test directory name.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <libgen.h>
#include <limits.h>
int main(int argc, char **argv) {
    char name[PATH_MAX], pidpath[PATH_MAX];
    snprintf(name,sizeof(name),"%s",argv[0]);
    char *dir=dirname(name);
    snprintf(pidpath,sizeof(pidpath),"%s/pid.txt",dir);
    FILE *pid=fopen(pidpath,"w"); if(pid){fprintf(pid,"%d",getpid());fclose(pid);}
    if(strstr(dir,"ignore-term")) signal(SIGTERM,SIG_IGN);
    if(strstr(dir,"large-out")){ for(int i=0;i<2000000;i++) putchar('x'); fflush(stdout); pause(); }
    if(strstr(dir,"large-err")){ for(int i=0;i<200000;i++) fputs("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n",stderr); fflush(stderr); pause(); }
    if(strstr(dir,"timeout")||strstr(dir,"cancel")){ for(;;)pause(); }
    if(strstr(dir,"agy")){
        if(argc!=6 || strcmp(argv[1],"--sandbox") || strcmp(argv[2],"--print-timeout") || strcmp(argv[3],"20s") || strcmp(argv[4],"--print") || strcmp(argv[5],"/usage")) {
            return 14;
        }
        puts("Quota:\nGemini Models Weekly Limit Remaining 75% 2027-01-15T08:00:00Z\nGemini Models Five Hour Limit Remaining 60% 2027-01-10T08:00:00Z\nArgon Models Weekly Limit Remaining 20% 2027-01-15T08:00:00Z");
        fflush(stdout);return 0;
    }
    char line[4096];
    if(!fgets(line,sizeof(line),stdin)||!strstr(line,"\"method\":\"initialize\""))return 11;
    puts("{\"id\":1,\"result\":{\"userAgent\":\"fixture\"}}");fflush(stdout);
    if(!fgets(line,sizeof(line),stdin)||!strstr(line,"initialized"))return 12;
    if(!fgets(line,sizeof(line),stdin)||!strstr(line,"account/rateLimits/read"))return 13;
    if(strstr(dir,"malformed")){puts("invalid");fflush(stdout);return 0;}
    printf("{\"id\":2,\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":42,\"windowDurationMins\":300}}}}");
    // No trailing newline exercises EOF tail parsing.
    fflush(stdout);
    if(strstr(dir,"success-ignore-term")){putchar('\n');fflush(stdout);for(;;)pause();}
    return 0;
}
