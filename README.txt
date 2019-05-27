1. Ensure all ROBIN prerequisites are met for the environment you are installing in. 

   Prerequisite details can be found at: https://s3-us-west-2.amazonaws.com/robinio-docs/5.1.1/install.html

2. Install ROBIN by running the following:

   $ /bin/bash install-robin.sh

   This will first validate that your environment is ready for ROBIN. After this check is successful, it will deploy the ROBIN operator 
   as well as launching the ROBIN custom resource.

   Note: Based on your environment you might be prompted for additional information whilst running the script such as your Access key
         when deploying on AWS. To avoid this edit the appropriate robin-<env>.yaml with values for the necessary options. For more
         details check the install documentation available at: https://s3-us-west-2.amazonaws.com/robinio-docs/5.1.1/install.html 

3. Verify the ROBIN pods are running and ready by running the command:

   $ kubectl describe robinclusters -n robinio 

   Under the Status section there should be a field labelled Phase, its value should be "Ready". 

4. Set the environment variable ROBIN_SERVER to the IP Address of your master node by running the command:

   $ source ~/robinenv 

5. Activate your ROBIN cluster license by running the following commands:

   $ robin login admin --password Robin123

   $ robin license activate <USERID>

   Note: You can get your User ID after registering on https://get.robin.io. The second command will only work if the host on which the
         ROBIN client is running on has an internet connection. If this is not the case please retrieve the license key by following
         the instructions at https://get.robin.io/activate and apply it using the command 'robin license apply <key>'. 

6. To get started check out the example workflow located at: https://s3-us-west-2.amazonaws.com/robinio-docs/5.1.1/examples.html

7. To uninstall ROBIN run the following command:

   $ /bin/bash install-robin.sh --uninstall