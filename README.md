# vFunction MODNET Workshop

This workshop covers deploying the .NET workshop package, learning and analysing the OMS-NET application, setting a baseline measurement, configuring Kiro with the vFunction extension and MCP tools, and using vFunction-assisted prompts to extract, specify, test, and modernise `OrderController`.

## Contents

- [Deploy the .NET workshop package](#deploy-the-net-workshop-package)
- [Learning](#learning)
- [Analysis walkthrough](#analysis-walkthrough)
- [Load the final measurement and set the baseline](#load-the-final-measurement-and-set-the-baseline)
- [Kiro setup](#kiro-setup)
- [Extract OrderController](#extract-ordercontroller)
- [Generate specifications](#generate-specifications)
- [Test the extracted service](#test-the-extracted-service)
- [Run the modernisation workflow](#run-the-modernisation-workflow)

## Deploy the .NET workshop package

_Allow approximately 20 minutes._

1. Connect to the Windows VM and open PowerShell with administrator privileges:

   **Start > PowerShell > right-click > Run as administrator**

2. Run the following commands:

   ```powershell
   cd C:\vFunctionLab
   git clone https://github.com/sam-cole-vfunction/oms-modnet-workshop.git
   cd oms-modnet-workshop
   .\deploy-oms.ps1 `
     -VFServerHost "http://172.2.0.4" `
     -VFEmail "myname@vfun.net" `
     -VFPassword "vFunction2021!" `
     -PackageUrl "https://portal.vfunction.com/file/AAC8kzj8NGJqIIo1NzpIXIxjAFJTOgCia9e-46Iev8cAPZS7R9yJ7p7nuYUPdFThjNI8Mgi66YJZfMcu62sJS-A6Y5ITgLxYbyu8xApBVNvLyKBWiJ446cvF9YpVVHz0qffysf-cT1PgTxZfBRkRg6saMfGGTD3Z5D1Oe8l35IWIYA/a9708a79-da47-47f1-9962-59e93b36c56f/vfunction-controller-windows-installation.v5.0.2144.zip"
   ```

   ![PowerShell running the workshop deployment script](images/image1.png)

## Learning

_Allow approximately 10 minutes._

1. Open Chrome and navigate to [http://172.2.0.4](http://172.2.0.4), the vFunction server.

   Log in with:

   - Email: `myname@vfun.net`
   - Password: `vFunction2021!`

   ![vFunction login screen](images/image2.png)

2. Check that the **OMS-NET** application is selected. The application name is shown at the top left.

3. Select `oms-controller` for discovery and click **Apply**.

   ![Selecting oms-controller for discovery](images/image3.png)

4. Click **Start Learning**.

   ![Start Learning button](images/image4.png)

5. The learning progress is displayed.

   ![vFunction learning progress screen](images/image5.png)

6. In a Command Prompt window, start the API test script to generate application activity:

   ```powershell
   .\use-apis.ps1 -Iterations 100 -DelayMs 500
   ```

   ![API test script running in a command window](images/image6.png)

7. When learning is complete, click **Stop**, then navigate to the **Analysis** tab.

   ![Completed learning session](images/image7.png)

8. The **Analysis** tab shows the results from learning.

   ![Analysis results](images/image8.png)

## Analysis walkthrough

_Allow approximately 10 minutes._

## Load the final measurement and set the baseline

_Allow approximately 5 minutes._

1. Open the **Measurements** menu and click **Import Measurement**.

   ![Import Measurement option](images/image9.png)

2. Select the final measurement:

   ```text
   C:\vFunctionLab\oms-modnet-workshop\OMSNET Final.zip
   ```

   Click **Open**.

   ![Selecting the OMSNET Final measurement file](images/image10.png)

3. Click **Import**.

   ![Import measurement confirmation](images/image11.png)

4. The final measurement is displayed.

   ![Final measurement analysis](images/image12.png)

5. Open the **Measurements** menu and click **Set as Baseline**. This generates the modernisation plan and TODOs.

   ![Set as Baseline menu option](images/image13.png)

6. Open the **Modernization** tab, select `.NET 10` as the target version, and enter `OMS` as the prefix name.

   ![Modernization settings](images/image14.png)

7. Click **Agentic Modernization** in the **Actions** menu and review the prompts that will be used for the .NET modernisation.

   ![Agentic Modernization prompts](images/image15.png)

## Kiro setup

_Authentication, vFunction plugin, MCP, and AWS Transform MCP. Allow approximately 15 minutes._

1. On the Windows VM, use Chrome to download and install Kiro. Accept all defaults during installation.

   [Download Kiro for Windows](https://prod.download.desktop.kiro.dev/releases/stable/win32-x64/signed/1.0.437/kiro-ide-1.0.437-stable-win32-x64.exe)

2. Open Kiro and authenticate by creating or reusing an AWS Builder ID. You can use your real email address because a token will be sent to it.

3. Open the project:

   ```text
   C:\vFunctionLab\win-oms\oms-net
   ```

4. Install the vFunction plugin from the Kiro Marketplace.

   ![vFunction plugin in the Kiro Marketplace](images/image16.png)

5. Select the vFunction plugin and log in to the vFunction server UI at [http://172.2.0.4](http://172.2.0.4).

   ![vFunction plugin login in Kiro](images/image17.png)

6. When authentication is complete, close the Chrome window.

   ![Successful vFunction authentication](images/image18.png)

7. In the vFunction extension, select:

   - Application: **OMS-NET**
   - Measurement: the latest measurement, indicated by the home icon

   ![Selecting the application and measurement in Kiro](images/image19.png)

8. Click **Download vFunction Power**, save it to the project folder, and follow the instructions to install it.

   ![vFunction Workflows power in Kiro](images/image20.png)

9. In the vFunction extension, click **Install MCP Tools**, then reload the window when prompted.

   ![Install MCP Tools option](images/image21.png)

10. Open the Kiro extension. The **Powers** and **MCP** interface is now enabled.

    ![Kiro Powers and MCP interface enabled](images/image22.png)

## Extract OrderController

_Allow approximately 10 minutes._

Enter the following prompt in Kiro:

```text
Use vFunction to extract the domain OrderController into a folder named extOrder
```

## Generate specifications

_Allow approximately 10 minutes._

Enter the following prompt in Kiro:

```text
Use vFunction to generate OpenSpec specifications for domain OrderController into a folder named specOrder
```

## Test the extracted service

_Allow approximately 10 minutes._

Enter the following prompt in Kiro:

```text
Use vFunction to generate integration tests for domain OrderController into new folder named testOrder
```

## Run the modernisation workflow

_Allow approximately 30 minutes._

1. Open the `extOrder` folder in Kiro using **File > Open Folder**.

2. In the vFunction extension:

   - Sign in if required.
   - Select the **OMS-NET** application.
   - Select the baseline measurement using the home icon.
   - Click **Install MCP Tools**.
   - Reload the window when prompted.

3. Enter the following prompt in Kiro:

   ```text
   Modernize the services with the vFunction workflow.
   ```
