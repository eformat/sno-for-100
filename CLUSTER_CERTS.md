### Configure Lets Encrypt

I use acme.sh all the time for generating Lets Encrypt certs, its easy and fast. The only downside is its also a bit of manual labour.

1. Create _caa.your-domain_ entries in your two Route53 hosted zones.

   Enter this as the **Record name**

   ```bash
   caa
   ```

   Enter this as the **Value**

   ```bash
   0 issuewild "letsencrypt.org;"
   ```

2. On the command line, export your AWS credentials.

   ```bash
   export AWS_ACCESS_KEY_ID=<aws key id>
   export AWS_SECRET_ACCESS_KEY=<aws secret access key>
   ```

3. Grab the cluster api and wildcard domain and export them as environment variables. We will create a Let's Encrypt cert with Subject Alternate names for these domains. 

   ```bash
   export LE_API=$(oc whoami --show-server | cut -f 2 -d ':' | cut -f 3 -d '/' | sed 's/-api././')
   export LE_WILDCARD=$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.domain}')
   ```

4. Clone the fabulous **acme.sh** git repo to your local machine.

   ```bash
   cd ~/git
   git clone https://github.com/Neilpang/acme.sh.git
   ```

5. Now run the acme shell script to create your certificate requests.

   ```bash
   ~/git/acme.sh/acme.sh --issue --dns dns_aws -d ${LE_API} -d *.${LE_WILDCARD} --dnssleep 100 --force --insecure
   ```

6. Once complete, your certificates will be downloaded and available in your home directory.

7. We can now configure the default OpenShift ingress router to use them.

   ```bash
   oc -n openshift-ingress delete secret router-certs
   oc -n openshift-ingress create secret tls router-certs --cert=/home/$USER/.acme.sh/${LE_API}/fullchain.cer --key=/home/$USER/.acme.sh/${LE_API}/${LE_API}.key
   oc -n openshift-ingress-operator patch ingresscontroller default --patch '{"spec": { "defaultCertificate": { "name": "router-certs"}}}' --type=merge
   ```
