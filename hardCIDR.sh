#!/bin/bash

# A tool to enumerate netblock CIDRs by querying RIRs & BGP ASN prefix lookups
# Currently queries: ARIN, RIPE NCC, APNIC, AfriNIC, LACNIC
#
# Queries are made for the Org name, network handles, org handles, customer handles,
# BGP prefixes, PoCs with target email domain, and 'notify' email address - used by
# some RIRs.
#
# Note that severl RIRs currently limit query results to 256 or less, so large
# target orgs may not return all results.
#
# LACNIC only allows query of ASN or IP address bloks & cannot search for Org names
# directly. The entire DB as been downloaded to a separate file for queries to this RIR.
# The file will be periodically updated to maintain accurate information.
#
# Output saved to two csv files - one for org & one for PoCs
# A txt file is also output with a full list of enumerated CIDRs
#
# Script makes use of tmp files during operation. A directory is created in /tmp/ based on the
# client domain name, where all files are written/removed/cleaned up.
#
# Running the script with no options queries ARIN only.
#
# Author: Jason Ashton (@ninewires)
# Created: 09/19/2016


###################################################################################################################

cat << "banner"

  █▄                                         ▄█  ▄████████  ▄█  ████████▄     ▄████████
  ███                                       ███  ███    ███ ███  ███   ▀███   ███    ███
  ███          ▄███████▄    ▄████████       ███  ███    █▀  ███▌ ███    ███   ███    ███
  █████████▄  ███    ███   ████▀▀▀▀▀ ▄█████████  ███        ███▌ ███    ███  ▄███▄▄▄▄██▀
  ███▀▀▀▀███ ███     ███   ███       ███    ███  ███        ███▌ ███    ███ ▀▀███▀▀▀▀▀
  ███    ███  ███    ███   ███       ███    ███  ███    █▄  ███  ███    ███ ▀█████████▄
  ███    ███   ██▄▄▄▄█████ ███       ███   ▄███  ███    ███ ███  ███   ▄███   ███    ███
  ███    █▀     ▀▀▀▀▀▀███   ▀█       ████████▀   ▀███████▀  █▀   ████████▀    ▀██    ███
  █▀                                                                                  ▀█

  A tool for locating target Organization netblocks
  Written by: Jason Ashton, TrustedSec
  Website: https://www.trustedsec.com
  Twitter: @ninewires

banner

GRN='\x1B[1;32m'
WHT='\x1B[1;37m'
RED='\x1B[1;31m'
NC='\x1B[0m'
scriptdir=$(readlink -f $0 | rev | cut -d'/' -f2- | rev | xargs -I "%" echo %/)
ccfilename='country-codes.txt'
sname=$(basename "$0")
dbfile='lacnicdb.txt'
dbfilepath="${scriptdir}$dbfile"
lf=$'\n'
tab=$'\t'
currentwd=$(pwd)

# Script help
f_help()
{
cat << script_help

usage: ./${sname} -r -l -f -p -h -u
-r = Query [R]IPE NCC (Europe/Middle East/Central Asia)
-l = Query [L]ACNIC   (Latin America & Caribbean)
-f = Query A[f]riNIC  (Africa)
-p = Query A[P]NIC    (Asia/Pacific)
-u = Update LACNIC data file <- dont run with other options
-h = help

script_help
}

# Script options
while getopts ":r l f p u h" opt; do
     case $opt in
          r)
               ripeopt=1
               ;;
          l)
               lacnicopt=1
               ;;
          f)
               afrinicopt=1
               ;;
          p)
               apnicopt=1
               ;;
          u)   
               update=1
               ;;
          h)
               f_help
               exit 1
               ;;
          \?)
               echo
               echo "Invalid option: -$OPTARG" >&2
               f_help
               exit 1
               ;;
     esac
done

# Option combo check
if ([[ $ripeopt -eq 1  ]] || [[ $lacnicopt -eq 1 ]] || [[ $afrinicopt -eq 1 ]] || [[ $apnicopt -eq 1 ]]) && [[ $update -eq 1 ]]; then
     echo
     echo -e "${RED}[!] ${WHT}Woah cowboy! We can't run the script ${RED}AND ${WHT}update at the same time o.O${NC}"
     echo -e "    ${WHT}Try again & double check the options before pressing ${GRN}GO ${WHT};-)${NC}"
     f_help
     exit 1
fi


###################################################################################################################

f_update()
{
# funcitinon to update the local LACNIC data file
#
# LACNIC published rate-limits:
#   100 queries every 5 minutes
#   1000 queries every 60 minutes
#
# The high side of these rates is one query every 3.6s, so we
# will sleep for 4s between queries to remain under the limit.
#
# At the time of this script creastion, the update will take
# approximately 28hrs to complete.
#
# There is currently no mechanism to monitor the connection state
# nor ability to resume a crashed update.

datafile="lacnicdb.txt"
datafilebu="lacnicdb.txt.bu"

# Catch termination
trap f_term SIGHUP SIGINT SIGTERM

f_term()
{
echo
echo -e "${RED}[!] ${WHT}Caught ${RED}ctrl+c${WHT}, removing all tmp files and restoring old data file.${NC}"
rm ${scriptdir}tmpftp
rm ${scriptdir}$datafile
mv ${scriptdir}$datafilebu ${scriptdir}$datafile
exit
}

# Backup existing file in case things get janky
echo
echo -e "${GRN}[*] ${WHT}Backing up existing data file in case something goes wrong.${NC}"
if [ -e ${scriptdir}$datafile ] && [ -e ${scriptdir}$datafilebu ]; then
     rm ${scriptdir}$datafilebu
fi

if [ -e ${scriptdir}$datafile ]; then
     mv ${scriptdir}$datafile ${scriptdir}$datafilebu
else
     echo
     echo -e "${RED}[!] $datafile ${WHT}not found in script directory. Continuing without backup.${NC}"
fi

# Get all assigned/allocated ranges
echo
echo -e "${GRN}[*] ${WHT}Downloading LACNIC delegation list.${NC}"
curl --silent http://ftp.lacnic.net/pub/stats/lacnic/delegated-lacnic-latest | grep -E 'assigned|allocated' | cut -d'|' -f4 > ${scriptdir}tmpftp

echo
echo -e "${GRN}[*] ${WHT}Querying LACNIC for all published ranges.${NC}"
echo -e "    *** This is going to take a while ***"

total=$(wc -l ${scriptdir}tmpftp | sed -e 's|^[ \t]*||' | cut -d' ' -f1)
while read range; do
     echo "Range=$range" >> ${scriptdir}$datafile
     whois -h whois.lacnic.net $range | grep -v '%' | sed 1,4d | sed '$ d' >> ${scriptdir}$datafile
     echo >> ${scriptdir}$datafile
     echo "################################################################################" >> ${scriptdir}$datafile
     echo >> ${scriptdir}$datafile
     echo -ne "\t$number of $total ranges"\\r
     let number=number+1
     sleep 4
done < ${scriptdir}tmpftp

echo
echo -e "${GRN}[*] ${WHT}That's a wrap.${NC}"

rm ${scriptdir}tmpftp
exit 1
}


###################################################################################################################

# Update LACNIC data file if option set
if [[ $update -eq 1 ]]; then
     f_update
fi


###################################################################################################################

# BGP route server pool
f_bgppool()
{
rs1=$(dig +short route-server.he.net)                  #Hurricane Electric
rs2=$(dig +short route-views.nwax.routeviews.org)      #Route-Views NWAX
rs3=$(dig +short route-views.chicago.routeviews.org)   #Route-Views Chicago
rs4=$(dig +short route-views.sfmix.routeviews.org)     #Route-Views SanFrancisco
rs5=$(dig +short route-server.eastlink.ca)             #Eastlink

ARRAYRS=( $rs1 $rs2 $rs3 $rs4 $rs5 )
rando=${ARRAYRS[$[RANDOM % ${#ARRAYRS[@]}]]}
randomrs=$(echo $rando)
ncrs="nc -nv $randomrs 23"                    
}

f_term()
{
echo
echo -e "${RED}[!] ${WHT}Caught ${RED}ctrl+c, ${WHT}aborting & cleaning up my mess in ${RED}$outdir${NC}"
echo
cd $currentwd
if [ -d $outdir ]; then
     rm -rf $outdir 2>/dev/null
fi
exit
}

# Check if ipcalc is installed
if [[ $ripeopt -eq 1 ]] || [[ $apnicopt -eq 1 ]] || [[ $lacnicopt -eq 1 ]] || [[ $afrinicopt -eq 1 ]]; then
     if ! [[ $(whereis -b ipcalc) == 'ipcalc: /usr/bin/ipcalc' ]]; then
          echo
          echo -e "${RED}[!] ${WHT}The selected script options utilize ${RED}ipcalc ${WHT}for CIDR conversion.${NC}"
          echo -e "${RED}[!] ${WHT}Install ${RED}ipcalc${WHT} and try again later :-)${NC}"
          exit 1
     fi
fi

# Check if LACNIC DB file with script
if [[ $lacnicopt -eq 1 ]]; then
     if ! [ -s "$dbfilepath" ]; then
          echo
          echo -e "The LACNIC database file ${RED}$dbfile${NC} is not located with ${WHT}$sname${NC}." 2>/dev/null
          echo -e "Place with ${WHT}$sname${NC} and try again. . ."
          exit 1
     fi
fi

# Get client name
echo
echo -e -n "Enter Client Name: "
read -e orginput

while [[ $orginput == "" ]]; do
     echo
     echo -e -n "Client name is ${RED}empty${NC}, please try again: "
     read -e orginput
done

# Get client email domain
echo
echo -e -n "Enter Client Email Primary Domain (domain.tld): "
read -e emaildomain

while ! [[ $emaildomain =~ ^[a-zA-Z0-9]+(-[a-zA-Z0-9]+)*\.[a-zA-Z]{2,5}$ ]]; do
     echo
     echo -e "${RED}$emaildomain${NC} Is Not Valid Domain Format" >&2
     echo -e -n "Ex: example.com or one-example.com, Try Again: "
     read -e emaildomain
done

# Check if country codes are used in email address
echo
echo -e -n "Does ${WHT}$orginput${NC} use country codes in email addresses? ${WHT}Y${NC} or ${WHT}N${NC}: "
read -e ccused

while [[ $ccused != "Y" ]] && [[ $ccused != "N" ]]; do
     echo
     echo -e -n "Please enter ${WHT}Y${NC} or ${WHT}N${NC}: "
     read -e ccused
done

# Check country code position in email address
if [[ $ccused == "Y" ]]; then
     echo
     echo -e -n "Are country codes before (B) domain name or after (A) TLD? ${WHT}B${NC} or ${WHT}A${NC}: "
     read -e ccpos

     while [[ $ccpos != "B" ]] && [[ $ccpos != "A" ]]; do
          echo
          echo -e -n "Please enter ${WHT}B${NC} or ${WHT}A${NC}: "
          read -e ccpos
     done
fi

# Create & check if output dir exists
emdomain=$(echo $emaildomain | cut -d'.' -f1)
outdir="/tmp/${emdomain}"
if [ -d $outdir ]; then
     echo
     echo -e -n "${RED}${outdir}/${NC} directory already exists, overwrite contents? ${WHT}Y${NC} or ${WHT}N${NC}: "
     read -e overwrite
 
     while [[ $overwrite != "Y" ]] && [[ $overwrite != "N" ]]; do
          echo
          echo -e -n "Please enter ${WHT}Y${NC} or ${WHT}N${NC}: "
          read -e overwrite
     done
     if [[ $overwrite == "Y" ]]; then
          cd $outdir
          rm * 2>/dev/null
          arindir=$outdir
     else
          TIME=$(date +"%H%M%S")
          newdir="${outdir}-${TIME}"
          mkdir $newdir
          cd $newdir
          arindir=$newdir
     fi
else
     mkdir $outdir
     arindir=$outdir
     cd $outdir
fi

# Check for names containing '&' or 'and' to search for both instances
if [[ $orginput == *'&'* ]]; then
     echo -e "${WHT}Client name contains an ${RED}&${WHT}. We will search for name with ${RED}and ${WHT}also.${NC} "
     echo $orginput > tmporglist
     echo $orginput | sed 's|\&|and|' >> tmporglist
elif [[ $orginput == *'and'* ]]; then
     echo -e "${WHT}Client name contains ${RED}and${WHT}. We will search for name with an ${RED}& ${WHT}also.${NC}"
     echo $orginput > tmporglist
     echo $orginput | sed 's|and|\&|' >> tmporglist
else
     echo $orginput > tmporglist
fi

# Catch termination
trap f_term SIGHUP SIGINT SIGTERM

# Create country codes file
countrycodes="11,AX,AF,AL,DZ,AS,AD,AO,AI,AQ,AG,AR,AM,AW,AU,AT,AZ,BS,BH,BD,BB,BY,BE,BZ,BJ,BM,BT,BO,BQ,BA,BW,BV,BR,IO,\
BN,BG,BF,BI,KH,CM,CA,CV,KY,CF,TD,CL,CN,CX,CC,CO,KM,CG,CD,CK,CR,CI,HR,CU,CW,CY,CZ,DK,DJ,DM,DO,EC,EG,SV,GQ,ER,EE,ET,\
FK,FO,FJ,FI,FR,GF,PF,TF,GA,GM,GE,DE,GH,GI,GR,GL,GD,GP,GU,GT,GG,GN,GW,GY,HT,HM,VA,HN,HK,HU,IS,IN,ID,IR,IQ,IE,IM,IL,\
IT,JM,JP,JE,JO,KZ,KE,KI,KP,KR,KW,KG,LA,LV,LB,LS,LR,LY,LI,LT,LU,MO,MK,MG,MW,MY,MV,ML,MT,MH,MQ,MR,MU,YT,MX,FM,MD,MC,\
MN,ME,MS,MA,MZ,MM,NA,NR,NP,NL,NC,NZ,NI,NE,NG,NU,NF,MP,NO,OM,PK,PW,PS,PA,PG,PY,PE,PH,PN,PL,PT,PR,QA,RE,RO,RU,RW,SH,\
BL,KN,LC,MF,PM,VC,WS,SM,ST,SA,SN,RS,SC,SL,SG,SX,SK,SI,SB,SO,ZA,GS,SS,ES,LK,SD,SR,SJ,SZ,SE,CH,SY,TW,TJ,TZ,TH,TL,TG,\
TK,TO,TT,TN,TR,TM,TC,TV,UG,UA,US,AE,GB,UM,UY,UZ,VU,VE,VN,VG,VI,WF,EH,YE,ZM,ZW"

echo "$countrycodes" | tr ',' '\n' > $ccfilename


###################################################################################################################

# RIPE NCC query function

f_ripe()
{
while read name; do
     echo
     echo -e "${GRN}[*] ${WHT}Enumerating CIDRs for ${GRN}$name ${WHT}Org Names via${NC} RIPE NCC"

     whois -h whois.ripe.net "$name" > tmporgname 2>&1
     if ! grep -q -E 'No entries found|Network is unreachable|No route to host' tmporgname; then
          echo -e "\t${GRN}[-] ${WHT}Found RIPE NCC Records for ${GRN}$name${NC}"
          grep 'inetnum' tmporgname | sed -e "s|  \+|$tab|g" | cut -d$'\t' -f2 > tmpinetnum
          rir="RIPE NCC"
          while read range; do
               whois -h whois.ripe.net "$range" | sed 's|  \+||g' | sed 's|,||g' > tmprange
               inetnum=$(grep 'inetnum' tmprange | cut -d':' -f2)
               inetnumhtml=$(echo $range | sed 's| |%20|g;s|-|%2D|g;s|,|%2C|g;s|\.|%2E|g;s|\&|%26|g')
               inetnumurl="https://apps.db.ripe.net/search/lookup.html?source=ripe&key=${inetnumhtml}&type=inetnum"
               org=$(grep -m1 'descr' tmprange | cut -d':' -f2)
               netname=$(grep 'netname' tmprange | cut -d':' -f2)
               country=$(grep 'country' tmprange | cut -d':' -f2 | tr '[:lower:]' '[:upper:]')
               cidr=$(ipcalc -r $range | grep -v 'deaggregate' | grep -m1 '/' | sed 's|  \+|,|g' | cut -d',' -f2)
               echo "$netname,$org,$inetnum,$inetnumurl,$country,$rir,$cidr" >> $orgoutfile
          done < tmpinetnum
     elif grep -q -E 'Network is unreachable|No route to host' tmporgname; then
          echo -e "\t${RED}[-] ${WHT}whois.ripe.net is unreachable. Check network connection & try again.${NC}"
     else
          echo -e "\t${RED}[-] ${WHT}No RIPE NCC records found for ${RED}$name${NC}"
     fi
done < tmporglist

rm tmporgname tmpinetnum tmprange 2>/dev/null
}


###################################################################################################################

# APNIC query function

f_apnic()
{
while read name; do
     echo
     echo -e "${GRN}[*] ${WHT}Enumerating CIDRs for ${GRN}$name ${WHT}Org Names via${NC} APNIC"

     whois -h whois.apnic.net "$name" > tmporgname
     if ! grep -q -E 'No entries found|Network is unreachable|No route to host' tmporgname; then
          echo -e "\t${GRN}[-] ${WHT}Found APNIC Records for ${GRN}$name${NC}"
          grep 'inetnum' tmporgname | sed "s|  \+|$tab|g" | cut -d$'\t' -f2 > tmpinetnum
          # get notify email address from inetnums
          grep 'e-mail' tmporgname | grep -i $emaildomain | sed "s|  \+|$tab|g" | cut -d$'\t' -f2 | sort -u > tmpemails

          # inverse lookup for email address & get associated orgnames/inetnums
          if [ -s tmpemails ]; then
               while read email; do
                    whois -h whois.apnic.net "$email" > tmplookup
                    grep 'nic-hdl' tmplookup | sed -e "s|  \+|$tab|g" | cut -d$'\t' -f2 | sort -u >> tmpnichdl
               done < tmpemails
               while read nichdl; do
                    #-i pn: Objects with matching admin-c, tech-c, zone-c, or cross-nfy attributes
                    whois -h whois.apnic.net -i pn "$nichdl" | sed -n '/inetnum/,/^$/p' > tmplookup
                    if grep -q 'inetnum' tmplookup; then
                         grep 'inetnum' tmplookup | sed "s|  \+|$tab|g" | cut -d$'\t' -f2 >> tmpinetnum
                    fi
               done < tmpnichdl
               sort -u tmpinetnum > tmpinetnum2
          fi

          # query by inetnum
          if [ -s tmpinetnum2 ]; then
               rir="APNIC"
               while read range; do
                    whois -h whois.apnic.net -x "$range" | sed 's|  \+||g' | sed 's|,||g' | sed -n '/inetnum/,/^$/p' > tmprange
                    inetnum=$(grep 'inetnum' tmprange | cut -d':' -f2)
                    inetnumhtml=$(echo $range | sed 's| |%20|g;s|-|%2D|g;s|,|%2C|g;s|\.|%2E|g;s|\&|%26|g')
                    inetnumurl="http://wq.apnic.net/apnic-bin/whois.pl?searchtext=${inetnumhtml}"
                    netname=$(grep 'netname' tmprange | grep -i $name | cut -d':' -f2)
                    org=$(grep -m1 'descr' tmprange | cut -d':' -f2)
                    country=$(grep 'country' tmprange | cut -d':' -f2 | tr '[:lower:]' '[:upper:]')
                    admin=$(grep 'admin-c' tmprange | cut -d':' -f2 | tr '\n' '/')
                    cidr=$(ipcalc -r $range | grep -v 'deaggregate' | grep -m1 '/' | sed 's|  \+|,|g' | cut -d',' -f2)
                    echo "$netname,$org,$inetnum,$inetnumurl,$country,$rir,$cidr" >> $orgoutfile
               done < tmpinetnum2
          fi
     elif grep -q -E 'Network is unreachable|No route to host' tmporgname; then
          echo -e "\t${RED}[-] ${WHT}whois.apnic.net is unreachable. Check network connection & try again.${NC}"
     else
          echo -e "\t${RED}[-] ${WHT}No APNIC Records found for ${RED}$name${NC}"
     fi
done < tmporglist

rm tmporgname tmpemails tmplookup tmpnichdl tmpinetnum tmpinetnum2 tmprange 2>/dev/null
}


###################################################################################################################

# LACNIC query function

f_lacnic()
{
while read name; do
     echo
     echo -e "${GRN}[*] ${WHT}Enumerating CIDRs for ${GRN}$name ${WHT}Org Owner via${NC} LACNIC"

     rir="LACNIC"

     # query LACNIC
     grep 'owner:' $dbfilepath | grep -i "$name" | sort -u | sed -e "s|  *|$tab|g" | cut -d$'\t' -f2 > tmpowners

     if [ -s tmpowners ]; then
          echo -e "\t${GRN}[-] ${WHT}Found LACNIC Records for ${GRN}$name${NC}"
          while read owner; do
               grep -B4 "$owner" $dbfilepath | grep 'inetnum' | sed -e "s|  *|$tab|g" | cut -d$'\t' -f2 | sort -u >> tmpinetnum
               grep -B4 "$owner" $dbfilepath | grep 'aut-num' | grep -v 'N/A' | sed -e "s|  *|$tab|g" | cut -d$'\t' -f2 | sort -u >> tmpasn
               sort -u tmpinetnum -o tmpinetnum
               sort -u tmpasn -o tmpasn
          done < tmpowners

          # query by inetnum
          if [ -s tmpinetnum ]; then
               while read inetnum; do
                    grep -B2 -A8 "$inetnum" $dbfilepath | sed 's|  *||g' > tmplookup
                    netname=$(grep 'ownerid:' tmplookup | cut -d':' -f2)
                    org=$(grep 'owner:' tmplookup | cut -d':' -f2 | sed 's|,||g')
                    country=$(grep 'country:' tmplookup | cut -d':' -f2)
                    range=$(grep 'Range=' tmplookup | cut -d'=' -f2)
                    mask=$(grep -m1 'inetnum:' tmplookup | cut -d'/' -f2)
                    cidr=$(echo "$range/$mask")
                    echo "$netname,$org,$inetnum,,$country,$rir,$cidr" >> $orgoutfile
               done < tmpinetnum
          fi

          # query by ASN
          if [ -s tmpasn ]; then
               while read asn; do
                    grep -m1 -B3 -A4 "$asn" $dbfilepath | sed 's|  *||g' > tmplookup
                    netname=$(grep 'ownerid:' tmplookup | cut -d':' -f2)
                    org=$(grep 'owner:' tmplookup | cut -d':' -f2 | sed 's|,||g')
                    country=$(grep 'country:' tmplookup | cut -d':' -f2)
                    num=$(echo $asn | sed 's|AS||g')
                    f_bgppool
                    (sleep 5; printf "%s\n" "sh ip bgp regexp _${num}$"; sleep 1; printf '\u0020'; sleep 1; printf '\u0020'; sleep 1; printf '\u0020'; sleep 1; printf '\u0020'; sleep 2; printf "%s\n" "exit") | $ncrs > tmpprefix 2>/dev/null
                    # get network address by cidr notation
                    sed 's|[>i]| |g' tmpprefix | sed 's|  |,|g' | sed 's| |,|g' | cut -d',' -f2 | grep -E -o '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}' > netaddrs
                    # get classful network address
                    sed 's|[>i]| |g' tmpprefix | sed 's|  |,|g' | sed 's| |,|g' | cut -d',' -f2 | grep -v '/' | grep -E -o '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' >> netaddrs
                    while read netaddr; do
                         if [[ $netaddr =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.0$ ]]; then
                              oct1=$(echo $netaddr | cut -d'.' -f1)
                              if [ $oct1 -ge 1 -a $oct1 -le 126 ]; then
                                   cidr='/8'
                              elif [ $oct1 -ge 128 -a $oct1 -le 191 ]; then
                                   cidr='/16'
                              elif [ $oct1 -ge 192 -a $oct1 -le 223 ]; then
                                   cidr='/24'
                              fi
                              sed -i "s|$netaddr|${netaddr}${cidr}|" netaddrs
                         fi
                    done < netaddrs
                    while read cidr; do
                         neturl=$(echo "http://bgp.he.net/${asn}#_prefixes")
                         echo "$netname,$org,$asn,$neturl,$country,$rir,$cidr" >> $orgoutfile
                    done < netaddrs
                    sleep 1
               done < tmpasn
          fi

          # query by eamil address
          grep -i "@${emaildomain}" $dbfilepath | sed 's|  *||g' | cut -d':' -f2 | sort -u > tmpemails
          if [ -s tmpemails ]; then
               while read email; do
                    grep -B25 "$email" $dbfilepath | grep 'inetnum:' | sed 's|  *||g' | cut -d':' -f2- > tmpinetnum
                    while read inetnum; do
                         grep -B2 -A16 "$inetnum" $dbfilepath | sed 's|  *||g' > tmplookup
                         netname=$(grep 'ownerid:' tmplookup | cut -d':' -f2)
                         org=$(grep 'owner:' tmplookup | cut -d':' -f2 | sed 's|,||g')
                         pochandle=$(grep 'nic-hdl:' tmplookup | cut -d':' -f2)
                         country=$(grep 'country:' tmplookup | cut -d':' -f2)
                         range=$(grep 'Range=' tmplookup | cut -d'=' -f2)
                         mask=$(grep -m1 'inetnum:' tmplookup | cut -d'/' -f2)
                         cidr=$(echo "$range/$mask")
                         echo "$org,,$pochandle,$email,,$country,$rir,$cidr" >> $pocoutfile
                    done < tmpinetnum
               done < tmpemails
          fi
     else
          echo -e "\t${RED}[-] ${WHT}No LACNIC Records found for ${RED}$name${NC}"
     fi
done < tmporglist

rm tmpowners tmpinetnum tmpasn tmplookup tmpprefix netaddrs tmpemails 2>/dev/null
}


###################################################################################################################

# AfriNIC query function

f_afrinic()
{
while read name; do
     echo
     echo -e "${GRN}[*] ${WHT}Enumerating CIDRs for ${GRN}$name ${WHT}Org Names via${NC} AfriNIC"

     whois -h whois.afrinic.net "$name" > tmporgname 2>&1
     if ! grep -q -E 'No entries found|Network is unreachable|No route to host' tmporgname; then
          echo -e "\t${GRN}[-] ${WHT}Found AfriNIC Records for ${GRN}$name${NC}"
          grep 'inetnum' tmporgname | sed -e "s|  \+|$tab|g" | cut -d$'\t' -f2 > tmpinetnum
          # get notify email address from inetnums
          grep 'notify' tmporgname | sed -e "s|  \+|$tab|g" | cut -d$'\t' -f2 | sort -un > tmpemails

          # inverse lookup for notify email address & get associated orgnames/inetnums
          if [ -s tmpemails ]; then
               while read email; do
                    whois -h whois.afrinic.net -i ny "$email" > tmplookup
                    grep -B1 -i "$name" tmplookup | grep 'inetnum' | sed -e "s|  \+|$tab|g" | cut -d$'\t' -f2 | sort -u >> tmpinetnum
               done < tmpemails
               grep -B1 -i "$name" tmplookup | grep 'netname' | sed -e "s|  \+|$tab|g" | cut -d$'\t' -f2 | sort -u > tmpnetname
               while read netname; do
                    whois -h whois.afrinic.net $netname | grep 'inetnum' | sed -e "s|  \+|$tab|g" | cut -d$'\t' -f2 >> tmpinetnum
               done < tmpnetname
               sort -u tmpinetnum > tmpinetnum2
          fi

          # query by inetnum
          if [ -s tmpinetnum2 ]; then
               rir="AfriNIC"
               while read range; do
                    whois -h whois.afrinic.net -x "$range" | sed 's|  \+||g' | sed 's|,||g' > tmprange
                    inetnum=$(grep 'inetnum' tmprange | cut -d':' -f2)
                    inetnumhtml=$(echo $range | sed 's| |%20|g;s|-|%2D|g;s|,|%2C|g;s|\.|%2E|g;s|\&|%26|g')
                    inetnumurl="http://www.afrinic.net/en/services/whois-query"
                    org=$(grep -m1 'descr' tmprange | cut -d':' -f2)
                    netname=$(grep 'netname' tmprange | cut -d':' -f2)
                    country=$(grep -m1 'country' tmprange | cut -d':' -f2 | tr '[:lower:]' '[:upper:]')
                    admin=$(grep -m1 'admin-c' tmprange | cut -d':' -f2 | tr '\n' '/')
                    cidr=$(ipcalc -r $range | grep -v 'deaggregate' | grep -m1 '/' | sed 's|  \+|,|g' | cut -d',' -f2)
                    echo "$netname,$org,$inetnum,$inetnumurl,$country,$rir,$cidr" >> $orgoutfile
               done < tmpinetnum2
          fi
     elif grep -q -E 'Network is unreachable|No route to host' tmporgname; then
          echo -e "\t${RED}[-] ${WHT}whois.afrinic.net is unreachable. Check network connection & try again.${NC}"
     else
          echo -e "\t${RED}[-] ${WHT}No AfriNIC Records found for ${RED}$name${NC}"
     fi
done < tmporglist

rm tmporgname tmpinetnum tmpemails tmplookup tmpnetname tmpinetnum2 tmprange 2>/dev/null
}


###################################################################################################################

# ARIN query

pocoutfile='poccidrs'
orgoutfile='orgcidrs'
pocfile='poccidrs.csv'
orgfile='orgcidrs.csv'
agent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/41.0.2227.0 Safari/537.36"
rir='ARIN'

while read name; do
     orghtml=$(echo $name | sed 's| |%20|g;s|-|%2D|g;s|,|%2C|g;s|\.|%2E|g;s|\&|%26|g')
     echo
     echo -e "${GRN}[*] ${WHT}Enumerating CIDRs for ${GRN}$name ${WHT}Org Handles via ${GRN}ARIN${NC}"

     echo 'AAAAA--placeholder--' > $orgoutfile

     # ARIN - get list of org networks
     # get org handles
     curl --silent http://whois.arin.net/rest/orgs\;name=${orghtml}* | sed "s|<|\\$lf|g" | grep '/rest/org/' > orginfo

     if [ -s orginfo ]; then
          echo -e "\t${GRN}[-] ${WHT}Found Org Handles for ${GRN}$name${NC}"
          while read line; do
               country='US'
               org=$(echo $line | cut -d'"' -f4 | sed 's|,||g')
               orghandle=$(echo $line | cut -d'"' -f2)
               # get list of org networks
               curl --silent https://whois.arin.net/rest/org/${orghandle}/nets | sed "s|<|\\$lf|g" | grep '/rest/net/' | rev | cut -d'>' -f1 | rev | sed 's|$|.txt|g' > orgs
               # get cidrs for each network
               while read neturl; do
                    curl --silent $neturl | sed -e "s|  \+|$tab|g" > nettmp
                    netname=$(grep 'NetName' nettmp | cut -d$'\t' -f2)
                    grep 'CIDR' nettmp | cut -d$'\t' -f2 | sed "s|, |\\$lf|g" > cidrtmp
                    while read cidr; do
                         echo "$org,$orghandle,$netname,$neturl,$country,$rir,$cidr" >> $orgoutfile
                    done < cidrtmp
                    sleep 1
               done < orgs
          done < orginfo
     else
          echo -e "\t${RED}[-]${WHT}No Org Handles found for ${GRN}$name${NC}"
     fi
done < tmporglist

rm orginfo orgs nettmp cidrtmp 2>/dev/null


###################################################################################################################

# ARIN - get list of customer handles

while read name; do
     orghtml=$(echo $name | sed 's| |%20|g;s|-|%2D|g;s|,|%2C|g;s|\.|%2E|g;s|\&|%26|g')
     echo
     echo -e "${GRN}[*] ${WHT}Enumerating CIDRs for ${GRN}$name ${WHT}Customer Handles via ${GRN}ARIN${NC}"

     curl --silent https://whois.arin.net/rest/customers\;name=${orghtml}* | sed "s|<|\\$lf|g" | grep '/rest/customer/' > custinfo

     if [ -s custinfo ]; then
          echo -e "\t${GRN}[-] ${WHT}Found Customer Handles for ${GRN}$name${NC}"
          while read line; do
               country='US'
               cust=$(echo $line | cut -d'"' -f4 | sed 's|,||g')
               custhandle=$(echo $line | cut -d'"' -f2)
               curl --silent https://whois.arin.net/rest/customer/${custhandle}/nets | sed "s|<|\\$lf|g" | grep '/rest/net/' | cut -d'>' -f2 | sed 's|$|.txt|' > custurls
               while read custurl; do
                    curl --silent $custurl | sed -e "s|  \+|$tab|g" > custtmp
                    netname=$(grep 'NetName' custtmp | cut -d$'\t' -f2)
                    neturl=$(grep 'Ref' custtmp | cut -d$'\t' -f2)
                    grep 'CIDR' custtmp | cut -d$'\t' -f2 | sed "s|, |\\$lf|g" > cidrtmp
                    while read cidr; do
                         echo "$cust,$custhandle,$netname,$neturl,$country,$rir,$cidr" >> $orgoutfile
                    done < cidrtmp
                    sleep 1
               done < custurls
          done < custinfo
     else
          echo -e "\t${RED}[-] ${WHT}No Customer Handles found for ${GRN}$name${NC}"
     fi
done < tmporglist

rm custinfo custurls custtmp cidrtmp 2>/dev/null


###################################################################################################################

# ARIN - get poc handle based on email domain
echo
echo -e "${GRN}[*] ${WHT}Enumerating CIDRs for PoCs with the ${GRN}$emaildomain ${WHT}Email Domain via ${GRN}ARIN${NC}"

if [[ $ccused == "Y" ]]; then
     if [[ $ccpos == "B" ]]; then
          cat $ccfilename | sed "s|$|\.${emaildomain}|" | tr '[:upper:]' '[:lower:]' | sort > emailtmp
          sed -i 's|11\.||' emailtmp
     elif [[ $ccpos == "A" ]]; then
          cat $ccfilename | sed "s|^|${emaildomain}\.|" | tr '[:upper:]' '[:lower:]' | sort > emailtmp
          sed -i 's|\.11||' emailtmp
     fi
else
     echo "$emaildomain" > emailtmp
fi

echo 'AAAAA--placeholder--' > $pocoutfile

# validate email domains
while read email; do
     curl --silent http://whois.arin.net/rest/pocs\;domain=@${email} > pocurltmp
     if ! grep -q 'Your search did not yield any results' pocurltmp; then
          echo -e "\t${GRN}[-] ${WHT}Found ARIN email Records for ${GRN}$email${NC}"
          sed "s|<|\\$lf|g" pocurltmp | grep -i 'handle' | rev | cut -d'>' -f1 | rev > poctmp
          while read url; do
               curl --silent ${url}.txt | grep -E 'Handle|Country|Email|Ref' | sed -e "s|  \+|$tab|g" > pocinfo
               pochandle=$(cat pocinfo | grep 'Handle' | cut -d$'\t' -f2)
               poccountry=$(cat pocinfo | grep 'Country' | cut -d$'\t' -f2)
               pocemail=$(cat pocinfo | grep 'Email' | cut -d$'\t' -f2 | tr '\n' '/')
               pocurl=$(cat pocinfo | grep 'Ref' | cut -d$'\t' -f2)
               # query for associated networks
               curl --silent ${url}/nets > urltmp
               if ! grep -q 'No related resources were found' urltmp; then
                    sed "s|<|\\$lf|g" urltmp | rev | cut -d' ' -f1 | rev | grep '/rest/net/' | cut -d'>' -f2 | sed 's|$|.txt|' > urltmp2
                    while read url; do
                         neturl=$(echo $url)
                         curl --silent $url | grep -E 'Organization|CIDR' | sed -e "s|  \+|$tab|g" > urltmp3
                         org=$(grep 'Organization' urltmp3 | cut -d$'\t' -f2 | sed 's|,||g')
                         grep 'CIDR' urltmp3 | cut -d$'\t' -f2 | sed "s|, |\\$lf|g" > cidrtmp
                         while read cidr; do
                              echo "$org,$neturl,$pochandle,$pocemail,$pocurl,$poccountry,$rir,$cidr" >> $pocoutfile
                         done < cidrtmp
                    done < urltmp2
               fi
               # query for associated orgs
               curl --silent ${url}/orgs > urltmp
               if ! grep -q 'No related resources were found' urltmp; then
                    sed "s|<|\\$lf|g" urltmp | grep 'rest/org/' | rev | cut -d'>' -f1 | rev | sort -u > urltmp2
                    while read url2; do
                         country='US'
                         orgurl=$(echo $url2)
                         curl --silent ${url2}/nets | sed "s|<|\\$lf|g" | grep 'rest/net/' | rev | cut -d'>' -f1 | rev > urltmp3
                         while read net; do
                              curl --silent ${net}.txt | grep -E 'Organization|CIDR' | sed -e "s|  \+|$tab|g" > urltmp4
                              org=$(grep 'Organization' urltmp4 | cut -d$'\t' -f2 | sed 's|,||g')
                              grep 'CIDR' urltmp4 | cut -d$'\t' -f2 | sed "s|, |\\$lf|g" > cidrtmp
                              while read cidr; do
                                   if [[ $ccused == "Y" ]]; then
                                        echo "$org,$orgurl,$pochandle,$pocemail,$pocurl,$poccountry,$rir,$cidr" >> $pocoutfile
                                   else
                                        echo "$org,$orgurl,$pochandle,$pocemail,$pocurl,$country,$rir,$cidr" >> $pocoutfile
                                   fi
                              done < cidrtmp
                         done < urltmp3
                    done < urltmp2
               fi
          done < poctmp
     else
          echo -e "\t${RED}[-] ${WHT}No ARIN Records found for ${GRN}$email${NC}"
     fi
done < emailtmp

rm pocurltmp poctmp pocinfo urltmp urltmp2 urltmp3 urltmp4 cidrtmp emailtmp 2>/dev/null


###################################################################################################################

# ARIN - query BGP route server

while read name; do
     orghtml=$(echo $name | sed 's| |%20|g;s|-|%2D|g;s|,|%2C|g;s|\.|%2E|g;s|\&|%26|g')
     f_bgppool
     echo
     echo -e "${GRN}[*] ${WHT}Enumerating CIDRs for ${GRN}$name ${WHT}BGP Prefixes via Route Server Pool Query${NC}"
     curl --silent http://whois.arin.net/rest/orgs\;name=${orghtml}* | sed "s|<|\\$lf|g" | grep '/rest/org/' > orginfo
     if [ -s orginfo ]; then
          while read orgname; do
               org=$(echo $orgname | cut -d'"' -f4 | sed 's|,||g')
               handle=$(echo $orgname | cut -d'"' -f2)
               curl --silent http://whois.arin.net/rest/org/${handle}/asns | sed "s|<|\\$lf|g" | grep '/rest/asn/' > handleasn
               if [ -s handleasn ]; then
                    sed -i "s|^|${handle},|" handleasn
                    sed -i "s|^|${org},|" handleasn
                    cat handleasn >> asinfo
               fi
          done < orginfo
          if [ -s asinfo ]; then
               while read asinfo; do
                    asn=$(echo $asinfo | rev | cut -d'/' -f1 | rev)
                    handle=$(echo $asinfo | cut -d',' -f2)
                    org=$(echo $asinfo | cut -d',' -f1)
                    country='US'
                    num=$(echo $asn | sed 's|AS||g')
                    echo -e "\t${GRN}[-] ${WHT}Found AS Records for ${GRN}${handle}${NC}"
                    f_bgppool
                    (sleep 5; printf "%s\n" "sh ip bgp regexp _${num}$"; sleep 1; printf '\u0020'; sleep 1; printf '\u0020'; sleep 1; printf '\u0020'; sleep 1; printf '\u0020'; sleep 2; printf "%s\n" "exit") | $ncrs > tmpprefix
                    # get network address by cidr notation
                    sed 's|[>i]| |g' tmpprefix | sed 's|  |,|g' | sed 's| |,|g' | cut -d',' -f2 | grep -E -o '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}' > netaddrs
                    # get classful network address
                    sed 's|[>i]| |g' tmpprefix | sed 's|  |,|g' | sed 's| |,|g' | cut -d',' -f2 | grep -v '/' | grep -E -o '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' >> netaddrs
                    while read netaddr; do
                         if [[ $netaddr =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.0$ ]]; then
                              oct1=$(echo $netaddr | cut -d'.' -f1)
                              if [ $oct1 -ge 1 -a $oct1 -le 126 ]; then
                                   cidr='/8'
                              elif [ $oct1 -ge 128 -a $oct1 -le 191 ]; then
                                   cidr='/16'
                              elif [ $oct1 -ge 192 -a $oct1 -le 223 ]; then
                                   cidr='/24'
                              fi
                              sed -i "s|$netaddr|${netaddr}${cidr}|" netaddrs
                         fi
                    done < netaddrs
                    while read cidr; do
                         neturl=$(echo "http://bgp.he.net/${asn}#_prefixes")
                         echo "$org,$handle,$asn,$neturl,$country,$rir,$cidr" >> $orgoutfile
                    done < netaddrs
                    sleep 2
               done < asinfo
          fi
     else
          echo -e "\t${RED}[-] ${WHT}No ASN Records found for ${GRN}$name${NC}"
     fi
done < tmporglist

rm orginfo handleasn asinfo tmpprefix netaddrs 2>/dev/null


###################################################################################################################

# Query additional RIRs

if [[ $ripeopt -eq 1 ]]; then
     f_ripe
fi

if [[ $apnicopt -eq 1 ]]; then
     f_apnic
fi

if [[ $lacnicopt -eq 1 ]]; then
     f_lacnic
fi

if [[ $afrinicopt -eq 1 ]]; then
     f_afrinic
fi


###################################################################################################################

# Output file sorting & clean-up

sort -t',' -k7 -n $orgoutfile | sort -u | sed 's|AAAAA--placeholder--|Organization/Customer,Org Handle/Description,Network Name/ASN,Network/ASN URL,Country Code,RIR,CIDR|' > $orgfile
if [[ $ccused == "Y" ]]; then
     sort -t',' -k8 -n $pocoutfile | sort -u | sed 's|AAAAA--placeholder--|Organization,Network URL,PoC Handle,PoC Email,PoC Handle URL,Country Code,RIR,CIDR|' > $pocfile
else
     sort -t',' -k8 -n $pocoutfile | sort -u | sed 's|AAAAA--placeholder--|Organization,Network URL,PoC Handle,PoC Email,PoC Handle URL,Country Code,RIR,CIDR|' > $pocfile
fi

cut -d',' -f7 $orgfile | grep -v 'CIDR' > cidrlist
cut -d',' -f8 $pocfile | grep -v 'CIDR' >> cidrlist
sort -t . -k1,1n -k2,2n -k3,3n -k4,4n -n -u cidrlist | sed '/^$/d' > cidrlist.txt

rm $orgoutfile $pocoutfile cidrlist $ccfilename tmporglist 2>/dev/null

echo
echo -e "!! Finally finished !!"
echo
echo -e "${GRN}[*] ${WHT}Org & Customer related CIDRs located in ${GRN}${arindir}/$orgfile${NC}"
echo -e "${GRN}[*] ${WHT}PoC related CIDRs located in ${GRN}${arindir}/$pocfile${NC}"
echo -e "${GRN}[*] ${WHT}CIDR only list located in ${GRN}${arindir}/cidrlist.txt${NC}"

cidercount=$(cat cidrlist.txt | wc -l)
if [ $cidercount -lt 1 ]; then
     echo
     echo -e  "${RED}[!] ${WHT}No CIDRs returned. Check the ${RED}Org ${WHT}and/or ${RED}email domain ${WHT}spelling & try again.${NC}"
fi
cd $currentwd