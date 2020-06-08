# hardCIDR

## Background
A Linux Bash script to discover the netblocks, or ranges, (in CIDR notation) 
owned by the target organization during the intelligence gathering phase of 
a penetration test. This information is maintained by the five Regional Internet 
Registries (RIRs):

*ARIN*    (North America)  
*RIPE*   (Europe/Asia/Middle East)  
*APNIC*   (Asia/Pacific)  
*LACNIC*  (Latin America)  
*AfriNIC*  (Africa)  

In addition to netblocks and IP addresses, Autonomous System Numbers (ASNs) are 
also of interest. ASNs are used as part of the Border Gateway Protocol (BGP) for 
uniquely identifying each network on the Internet. Target organizations may have 
their own ASNs due to the size of their network or as a result of redundant service 
paths from peered service providers. These ASNs will reveal additional netblocks 
owned by the organization.

## Requirements
ipcalc	(for RIPE, APNIC, LACNIC, AfriNIC queries)

## LACNIC
A note on LACNIC before diving into the usage. LACNIC only allows query of either 
network range, ASN, Org Handle, or PoC Handle. This does not help us in locating 
these values based upon the organization name. They do however publish a list of 
all assigned ranges on a publically accessible FTP server, along with their 
rate-limiting thresholds. So, there is an accompanying data file, which the script 
checks for, used to perform LACNIC queries locally. The script includes an update 
option **-r**, that can be used to update this data on an interval of your choosing. 
Approximate run time is just shy of 28 hours.

## Usage
The script with no specified options will query ARIN and a pool of BGP route servers. 
The route server is selected at random at runtime. The **-h** option lists the help:

![](https://www.trustedsec.com/wp-content/uploads/2017/03/img1.png)

The options may be used in any combination, all, or none. Unfortunately, none of the 
“other” RIRs note the actual CIDR notation of the range, so `ipcalc` is used to perform 
this function. If it is not installed on your system, the script will install it for you.

At the prompts, enter the organization name, the email domain, and whether country codes 
are used as part of the email. If answered **Y** to country codes, you will be prompted as 
to whether they precede the domain name or are appended to the TLD. A directory will be 
created for the output files in /tmp/. If the directory is found to exist, you will be 
prompted whether to overwrite. If answered **N**, a time stamp will be appended to the 
directory name.

![](https://www.trustedsec.com/wp-content/uploads/2017/03/img2.png)

The script queries each RIR, as well as a BGP route server, prompting along the way as 
to whether records were located. Upon completion, three files will be generated: a CSV 
based on Org Handle, a CSV based on PoC Handle, and a line delimited file of all located 
raanges in CIDR notation.

![](https://www.trustedsec.com/wp-content/uploads/2017/03/img3.png)

Cancelling the script at any time will remove any temporary working files and the directory 
created for the resultant output files.

![](https://www.trustedsec.com/wp-content/uploads/2017/03/img4.png)

It should be noted that, due to similarity in some organization names, you could get back 
results not related to the target. The CSV files will provide the associated handles and 
URLs for further validation where necessary. It is also possible that employees of the 
target organization used their corporate email address to register their own domains. 
These will be found within the results as well.

## Additional Information
For more information, check out the blog post on the TrustedSec website:
[Classy Inter-Domain Routing Enumeration](https://www.trustedsec.com/blog/classy-inter-domain-routing-enumeration/)
