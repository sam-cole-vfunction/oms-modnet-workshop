<#
.SYNOPSIS
    Exercises all OMS.NET API endpoints for vFunction learning.

.DESCRIPTION
    PowerShell equivalent of script/use-apis-net.sh.
    Calls every API endpoint (orders, inventory, shipping, products, store search,
    modify fulfillment) to generate traffic for vFunction dynamic analysis.

.PARAMETER BaseUrl
    The base URL of the OMS.NET API (default: http://dev.oms.net/api)

.PARAMETER Iterations
    Number of times to loop through all APIs (default: 1)

.PARAMETER DelayMs
    Milliseconds to wait between iterations (default: 500)
#>

param(
    # BaseUrl must point at the OMS.NET application (served by IIS), NOT the vFunction
    # server. 172.2.0.4 is the vFunction portal/server ($VFServerHost) - it answers GET
    # on some /api/* paths but returns 405 for POST/PATCH, which is what caused every
    # write to fail. The OMS.NET app is bound to dev.oms.net (and localhost:8080) by
    # deploy-oms.ps1.
    [string]$BaseUrl = "http://dev.oms.net/api",
    [int]$Iterations = 1,
    [int]$DelayMs = 500
)

$ErrorActionPreference = "Continue"

# Serialize to a JSON ARRAY, even when there is only one element.
# Windows PowerShell's "@(oneItem) | ConvertTo-Json" unwraps the single-element
# array and emits a bare object "{...}". Endpoints that bind to SalesOrder[] /
# Inventory[] then fail model binding and return an empty-body 500. Forcing the
# outer brackets guarantees a valid JSON array for the array-typed endpoints.
function ConvertTo-JsonArray {
    param(
        [Parameter(Mandatory = $true)] $Items,
        [int]$Depth = 5
    )
    $json = $Items | ConvertTo-Json -Depth $Depth
    if ($json.TrimStart().StartsWith("[")) {
        return $json
    }
    return "[" + $json + "]"
}

function Invoke-Api {
    param(
        [string]$Method = "GET",
        [string]$Uri,
        [string]$Body,
        [string]$Description
    )
    Write-Host "  $Method $Uri" -ForegroundColor Gray
    try {
        $params = @{
            Method      = $Method
            Uri         = $Uri
            ContentType = "application/json"
            UseBasicParsing = $true
            TimeoutSec  = 30
        }
        if ($Body) {
            $params["Body"] = $Body
        }
        $response = Invoke-WebRequest @params
        Write-Host "    -> $($response.StatusCode) OK" -ForegroundColor Green
    }
    catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code) {
            Write-Host "    -> HTTP $code" -ForegroundColor Yellow
        }
        else {
            Write-Host "    -> ERROR: $_" -ForegroundColor Red
        }
    }
}

Write-Host ""
Write-Host "OMS.NET API Exercise Script" -ForegroundColor Cyan
Write-Host "Base URL: $BaseUrl" -ForegroundColor Cyan
Write-Host "Iterations: $Iterations" -ForegroundColor Cyan
Write-Host ""

for ($i = 1; $i -le $Iterations; $i++) {
    if ($Iterations -gt 1) {
        Write-Host "--- Iteration $i of $Iterations ---" -ForegroundColor White
    }

    # Generate unique IDs for this iteration
    $orderId = [System.Math]::Abs([System.Random]::new().Next())
    $orderLineId = [System.Math]::Abs([System.Random]::new().Next())
    $sku = "SKU-$([System.Random]::new().Next(1000,99999))"

    # =========================================================================
    # ORDER APIs
    # =========================================================================
    Write-Host "`n[Orders]" -ForegroundColor Cyan

    # Create an order
    $orderBody = @{
        customerOrderId = "$orderId"
        primaryPhone = "9525944805"
        customerEmailId = "test@oms.net"
        firstName = "Test"
        orderStatus = "SUBMITTED"
        billToAddress = @{
            billToAddressId = "101"
            firstName = "Test"
            lastName = "User"
            city = "BLOOMINGTON"
            state = "MN"
            zipCode = "55344"
        }
        paymentInfo = @{
            paymentId = "234"
            paymentStatus = "SUCCESS"
            cardType = "VISA"
            authorizedAmount = 50.0
            collectedAmount = 5.0
        }
        charges = @{
            chargesId = "678"
            totalCharges = 10.0
        }
        orderLines = @(
            @{
                lineItemId = "$orderLineId"
                customerOrderId = "$orderId"
                primeLineNumber = "1"
                subLineNumber = "1"
                customerSKU = "$sku"
                shipToAddress = @{
                    shipToAddressId = "102"
                    firstName = "Test"
                    lastName = "User"
                    city = "BLOOMINGTON"
                    state = "MN"
                    zipCode = "55344"
                }
                LineCharges = @{
                    LineChargesId = "678"
                    totalCharges = 10.0
                }
                LineChargesId = 3
            }
        )
    } | ConvertTo-Json -Depth 5

    Invoke-Api -Method POST -Uri "$BaseUrl/order" -Body $orderBody -Description "Create order"

    # Get order
    Invoke-Api -Method GET -Uri "$BaseUrl/order/$orderId" -Description "Get order"

    # Create multiple orders.
    # NOTE: the order's customerOrderId and its order line's customerOrderId MUST match
    # (they form the parent/child relationship persisted by SaveOrder). Previously these
    # were generated as independent random values, which produced a server-side 500 on
    # /order/multi. Compute the IDs once and reuse them, mirroring the single-order payload.
    $multiOrderId = "$([System.Math]::Abs([System.Random]::new().Next()))"
    $multiLineId  = "$([System.Math]::Abs([System.Random]::new().Next()))"
    $multiOrders = @(
        @{
            customerOrderId = $multiOrderId
            primaryPhone = "9525944805"
            customerEmailId = "multi@oms.net"
            orderStatus = "SUBMITTED"
            firstName = "Multi"
            billToAddress = @{ billToAddressId = "101"; firstName = "Multi"; lastName = "Order"; city = "BLOOMINGTON"; state = "MN"; zipCode = "55344" }
            shipToAddress = @{ shipToAddressId = "102"; firstName = "Multi"; lastName = "Order"; city = "BLOOMINGTON"; state = "MN"; zipCode = "55344" }
            orderLines = @(@{
                lineItemId = $multiLineId
                customerOrderId = $multiOrderId
                primeLineNumber = "1"; subLineNumber = "1"; customerSKU = "SM-S20-BLK"
                shipToAddress = @{ shipToAddressId = "102"; firstName = "Multi"; lastName = "Order"; city = "BLOOMINGTON"; state = "MN"; zipCode = "55344" }
                LineCharges = @{ LineChargesId = "601"; totalCharges = 10.0 }; LineChargesId = 1
            })
            paymentInfo = @{ paymentId = "234"; paymentStatus = "SUCCESS"; cardType = "VISA"; authorizedAmount = 43.0; collectedAmount = 5.0 }
            charges = @{ chargesId = "601"; totalCharges = 10.0 }
        }
    )
    $multiOrders = ConvertTo-JsonArray -Items $multiOrders -Depth 5

    Invoke-Api -Method POST -Uri "$BaseUrl/order/multi" -Body $multiOrders -Description "Create multiple orders"

    # =========================================================================
    # INVENTORY APIs
    # =========================================================================
    Write-Host "`n[Inventory]" -ForegroundColor Cyan

    # Create inventory
    $invBody = @{
        skuId = "$sku"
        storeId = "10"
        quantity = 20
    } | ConvertTo-Json

    Invoke-Api -Method POST -Uri "$BaseUrl/inventory" -Body $invBody -Description "Create inventory"

    # Get inventory
    Invoke-Api -Method GET -Uri "$BaseUrl/inventory/$sku" -Description "Get inventory"

    # Create multiple inventories
    $multiInv = @(
        @{ skuId = "SM-S20-BLK"; storeId = "11"; quantity = 20 },
        @{ skuId = "SM-S20-WHT"; storeId = "11"; quantity = 25 },
        @{ skuId = "IPHN-12-64-MINI-BLK"; storeId = "11"; quantity = 13 }
    )
    $multiInv = ConvertTo-JsonArray -Items $multiInv -Depth 3

    Invoke-Api -Method POST -Uri "$BaseUrl/inventory/multi-create" -Body $multiInv -Description "Create multiple inventories"

    # =========================================================================
    # SHIPPING APIs
    # =========================================================================
    Write-Host "`n[Shipping]" -ForegroundColor Cyan

    # Create shipping record
    $shippingBody = @{
        skuId = "$sku"
        standardShipping = 10.0
        expeditedShipping = 15.0
        expressShipping = 20.0
    } | ConvertTo-Json

    Invoke-Api -Method POST -Uri "$BaseUrl/shipping" -Body $shippingBody -Description "Create shipping"

    # Get shipping
    Invoke-Api -Method GET -Uri "$BaseUrl/shipping/$sku" -Description "Get shipping"

    # =========================================================================
    # STORE SEARCH APIs
    # =========================================================================
    Write-Host "`n[Store Search]" -ForegroundColor Cyan

    Invoke-Api -Method GET -Uri "$BaseUrl/store/07470" -Description "Find stores by zip"

    # =========================================================================
    # MODIFY FULFILLMENT APIs
    # =========================================================================
    Write-Host "`n[Modify Fulfillment]" -ForegroundColor Cyan

    $mfBody = @{ customerOrderId = "$orderId" } | ConvertTo-Json

    # Shipping to pickup
    Invoke-Api -Method PATCH -Uri "$BaseUrl/modify/fulfillment/store/items/$orderLineId" -Body $mfBody -Description "Modify fulfillment: ship-to-pickup"

    # Pickup to shipping
    Invoke-Api -Method PATCH -Uri "$BaseUrl/modify/fulfillment/shipping/items/$orderLineId" -Body $mfBody -Description "Modify fulfillment: pickup-to-ship"

    # =========================================================================
    # PRODUCT APIs
    # =========================================================================
    Write-Host "`n[Products]" -ForegroundColor Cyan

    # Register products
    $products = @(
        @{ productId = "SM-S20-BLK"; name = "S20 Black"; description = "Samsung S20 Black"; manuf = "Samsung" },
        @{ productId = "SM-S20-WHT"; name = "S20 White"; description = "Samsung S20 White"; manuf = "Samsung" },
        @{ productId = "IPHN-12-64-MINI-BLK"; name = "IPhone 12 Mini 1"; description = "IPhone 12 Mini 64GB Black"; manuf = "Apple" },
        @{ productId = "IPHN-12-64-MINI-WHT"; name = "IPhone 12 Mini 2"; description = "IPhone 12 Mini 64GB White"; manuf = "Apple" },
        @{ productId = "IPHN-12-64-MINI-GRN"; name = "IPhone 12 Mini 3"; description = "IPhone 12 Mini 64GB Green"; manuf = "Apple" }
    )
    $products = ConvertTo-JsonArray -Items $products -Depth 3

    # Register a single product (POST /api/product/register). This exercises the
    # single-register HTTP route directly (register-list only hits it internally).
    $singleProduct = @{
        productId = "SM-S21-BLU"; name = "S21 Blue"; description = "Samsung S21 Blue"; manuf = "Samsung"
    } | ConvertTo-Json -Depth 3
    Invoke-Api -Method POST -Uri "$BaseUrl/product/register" -Body $singleProduct -Description "Register a single product"

    Invoke-Api -Method POST -Uri "$BaseUrl/product/register-list" -Body $products -Description "Register products"

    # Query products
    Invoke-Api -Method GET -Uri "$BaseUrl/product/IPHN-12-64-MINI-WHT" -Description "Get product by ID"
    Invoke-Api -Method GET -Uri "$BaseUrl/product/all" -Description "Get all products"
    Invoke-Api -Method GET -Uri "$BaseUrl/product/name/S20%20White" -Description "Find product by name"
    Invoke-Api -Method GET -Uri "$BaseUrl/product/desc-includes/green" -Description "Find product by description"
    Invoke-Api -Method GET -Uri "$BaseUrl/product/orderlines/SM-S20-BLK" -Description "Get order lines by product"
    Invoke-Api -Method GET -Uri "$BaseUrl/product/charges/SM-S20-BLK" -Description "Get charges for product"
    Invoke-Api -Method GET -Uri "$BaseUrl/product/inv-desc/iphone" -Description "Find inventory by product description"
    Invoke-Api -Method GET -Uri "$BaseUrl/product/inv/IPHN-12-64-MINI-WHT" -Description "Find product by inventory ID"

    # Find inventory by product id (inventory controller)
    Invoke-Api -Method GET -Uri "$BaseUrl/inventory/IPHN-12-64-MINI-BLK" -Description "Get inventory by SKU"

    # =========================================================================
    # VALUES APIs (default Web API scaffold - covers the remaining Help-page
    # endpoints and the only PUT/DELETE verbs in the app)
    # =========================================================================
    Write-Host "`n[Values]" -ForegroundColor Cyan

    Invoke-Api -Method GET    -Uri "$BaseUrl/values"    -Description "Get all values"
    Invoke-Api -Method GET    -Uri "$BaseUrl/values/5"  -Description "Get value by id"
    Invoke-Api -Method POST   -Uri "$BaseUrl/values"    -Body '"sample-value"' -Description "Create value"
    Invoke-Api -Method PUT    -Uri "$BaseUrl/values/5"  -Body '"updated-value"' -Description "Update value by id"
    Invoke-Api -Method DELETE -Uri "$BaseUrl/values/5"  -Description "Delete value by id"

    # =========================================================================

    if ($i -lt $Iterations -and $DelayMs -gt 0) {
        Start-Sleep -Milliseconds $DelayMs
    }
}

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Green
Write-Host " All API calls completed." -ForegroundColor Green
Write-Host "=====================================================" -ForegroundColor Green
Write-Host ""
Write-Host "To run in a loop for vFunction learning:" -ForegroundColor Yellow
Write-Host "  .\use-apis.ps1 -Iterations 100 -DelayMs 500" -ForegroundColor Yellow
Write-Host ""
