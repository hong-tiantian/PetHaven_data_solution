# PetHaven - Assignment 2 Spec: Business Case and Prototype Scope (v5)

1 Oct 2026 · Group 3 · Internal guide, not a submission

This guide defines the business problem, the three source databases, the actions that create their records, and the stock rules the prototype must follow. It also sets the boundary for the later solution design. Table names below describe the records we need; final keys, constraints, and SQL will be developed separately.

PetHaven is fictional. Its size, operating arrangements, and update schedules below are fixed definitions for this project. External sources support the retail practices and terms used here; they do not establish PetHaven's internal architecture or processing times.

## 1. What PetHaven is

PetHaven Group Pty Ltd is a fictional, mid-sized Australian retailer selling products for pets.

| Item | Project definition |
| --- | --- |
| Products | Pet food, treats, toys, accessories, and health-care items. PetHaven does not sell animals. |
| Stores | 30 stores across Sydney. Each has a shop floor, back room, and collection counter. |
| Distribution centre (DC) | One physical warehouse. It receives supplier deliveries and sends products to stores and home-delivery customers. |
| Product range | About 10,000 active products. Each product has a SKU and one or more barcodes. |
| Sales channels | In store, through a POS till; online, through the website or app. |
| Click & Collect (C&C) | An online order fulfilled from stock already at the customer's selected store. Staff pick the goods, set them aside, and hand them over when the customer collects. |
| Home delivery | An online order fulfilled from the DC. It is background context; the main prototype cases concern C&C. |
| Business scale | About 6,000 in-store sales and 2,000 online orders per day; online sales represent about 30% of revenue. These are case assumptions, not measured results. |
| Other offerings | Grooming at some stores is provided externally. Grooming and customer membership management are outside this project. |

Use these distinctions consistently:

- **Channel:** how the customer buys, in store or online.
- **Offering:** what the business sells, such as pet food or a grooming service.
- **Fulfilment:** how an online order reaches the customer, through collection or home delivery.
- **Location:** where products physically are, such as Parramatta store or the DC.

C&C is an online sale even though the customer collects in store. The collection is not recorded again as a new till sale.

## 2. One business problem

### 2.1 Problem statement

> PetHaven accepts Click & Collect orders that the selected store cannot fulfil because the website's stock information does not reflect recent in-store sales. The website uses a stock balance copied each morning and adjusts it for its own online orders. Store sales are recorded immediately in the store sales database, but are incorporated into central stock overnight and reach the website in its next morning refresh. Staff discover the shortage when picking an order and must contact the customer, cancel and refund the order, or arrange another fulfilment option.

The customer experiences a cancelled or delayed order. Store staff spend time checking stock and contacting the customer. PetHaven risks losing the sale and the customer's confidence in its availability information.

The main cause investigated here is **the delay between recording an event in one database and using it in another**. A connected till can record a sale immediately while the website still uses yesterday's stock balance.

One business problem can have several contributing causes and several example cases. Product and location codes must also be matched when combining the records. That is a supporting data requirement within the stock problem, not a separate customer-data project.

### 2.2 Scope

The main unit of analysis is **one product at one location at a specified time**. The cases cover a product sold in store after the website refresh, and a remaining item already promised to another C&C order.

Supplier receipts, transfers, and recorded adjustments are included because they change the stock calculation. They do not introduce a separate supply-chain optimisation problem.

Customer duplicate detection, pet profiles, grooming records, supplier selection, transfer-route planning, and split fulfilment are outside scope. Each prototype C&C order uses one pickup store, and its lines are collected or cancelled together. Returns after collection and partial fulfilment are left for future extension. The prototype does retain pre-collection cancellations and their history.

## 3. Fixed operating rules

### 3.1 What the three sources are

An operational system supports daily work through an application and its database. The three sources used by this project are the databases holding that work:

| Operational system | Application used | Source database | Main responsibility |
| --- | --- | --- | --- |
| In-store POS system | Till software used by store staff | **Store sales database** | Records completed in-store sales and their lines |
| Online store | Website/app and order-management screens | **Online orders database** | Records online orders, their status history, and the stock copy used online |
| Central stock system | Stock screens used by DC, store receiving, and stock-control staff | **Central stock database** | Records products, locations, stock movements, transfers, and stock balances |

When a till saves a sale over its network connection, it sends the record to the **store sales database**, not to the shopping website. “Online till” means connected; “online store” means the customer-facing sales application.

These are three logical business sources. The lab may represent them through separate source schemas, such as `src_store_sales`, `src_online`, and `src_stock`. Sharing a lab DBMS does not make their business roles or update schedules identical. Raw, cleaned, and warehouse schemas are processing stages, not additional source systems.

### 3.2 Connectivity and update schedule

PetHaven's tills remain connected to the store sales database throughout the operating period modelled here. Each completed sale is saved immediately. Network outages are outside scope.

All example times use Sydney local time. The implementation must store unambiguous timestamps and distinguish when an event happened from when another system processed it.

| Action or processing step | Timing in the existing business | Result |
| --- | --- | --- |
| Till sale completed | Immediately | Sale and sale lines enter the store sales database |
| Online order placed, cancelled, marked ready, or collected/shipped | Immediately when the customer or staff completes the action | Current order status and a history event enter the online orders database |
| Supplier receipt, transfer dispatch/receipt, or stock adjustment confirmed | When staff confirms the physical action | A dated movement is recorded in the central stock database |
| Central processing of its locally recorded movements | Hourly | Its current recorded on-hand quantities reflect those processed movements; store sales and online collections can still be missing |
| Central import of store sales and collected/shipped online orders | 1 am each day, for events before midnight | Imported reductions are applied once; central also produces a reconciled stock snapshot for the midnight cutoff |
| Website stock refresh | 5 am each day | Copies that fixed midnight snapshot, then accounts for its own online activity as described in §5.3 |

A **midnight cutoff** separates events before 00:00 from events at or after 00:00. The 1 am processing time is not the stock snapshot's effective time. The 5 am copy time does not make that midnight balance a 5 am physical count.

Central's current recorded quantity can combine recent receipts with older sales information. For this reason, the prototype uses the **dated, reconciled midnight snapshot** as its opening balance, rather than treating any current central number as fully up to date.

### 3.3 Where stock is held

“Central” means one system manages the records. It does not mean the stock is stored together or that every store can sell every unit in the network.

| Product | Location | Example recorded on hand |
| --- | --- | ---: |
| Royal Canin dog food 3 kg | Parramatta store | 5 |
| Royal Canin dog food 3 kg | Chatswood store | 8 |
| Royal Canin dog food 3 kg | DC | 40 |

These are separate balances. When Sarah selects Parramatta, the website uses its copied balance for **that product at Parramatta**, not the network total of 53. The product page may display only “In stock”; the internal calculated quantity is shown in this guide to explain the behaviour.

At a store, on-hand stock includes goods on the shop floor, in the back room, and set aside behind the collection counter. Goods travelling from the DC to a store are **in transit** and cannot yet be promised for collection at that store. The physical DC is different from the data warehouse used for integrated reporting.

## 4. How business actions create the three sources

### 4.1 Source 1: store sales database

**Business activity:** a customer purchases products at a store counter.

1. A customer takes one bag of Royal Canin dog food to a Parramatta till.
2. A staff member scans its barcode. The till retrieves the product description and price from its product list.
3. Payment succeeds and the sale is completed. The till saves the sale and its lines to the connected store sales database immediately.
4. The customer leaves with the bag, so physical stock at Parramatta falls by one.
5. Central stock has not yet imported that sale. The website also has not received it, so neither immediately reduces its recorded quantity for this event.
6. At the next 1 am import, central records the sale's stock reduction. At 5 am, the website obtains the resulting midnight stock snapshot.

The sale is present in its source even while downstream stock records are outdated. The issue is delayed use of the data, not an offline till.

| Candidate records | What one record means | Required information |
| --- | --- | --- |
| `sale` | One completed till purchase | Source sale ID, store code, till ID, completion time, source recording time |
| `sale_line` | One product line within a sale | Sale ID, line ID, scanned barcode, quantity, unit price |
| Till product/store reference records | Product and store codes the till uses | Barcode, description, price, store code |

A purchase containing three different products has one sale header and three sale lines. Stock is reduced by each line's quantity. A till does not maintain the project's authoritative stock balance or online reservations. Scanning an item without completing the purchase does not create a completed sale in this prototype.

**Why this source is needed:** it contains recent in-store stock reductions that have not yet reached central stock or the website.

### 4.2 Source 2: online orders database

**Business activity A: a customer places a C&C order.**

1. Sarah chooses the product and Parramatta as her pickup store on the website.
2. The online application checks its calculated availability for that product/location, using its stored stock copy and its own online activity.
3. If that calculation says enough stock is available, the application accepts the order and saves its header and lines.
4. The order starts as `awaiting_pick`. Its quantity becomes an active reservation immediately, even before staff physically sets goods aside.
5. The online application reduces its calculated availability. The store sales database records nothing, because this is an online order rather than a till purchase.
6. Central does not reduce physical on-hand stock merely because the order was placed. The goods have not left the store.

**Business activity B: staff picks and hands over the order.**

Staff uses the online order-management screen to find the order. After picking the goods and placing them behind the counter, staff marks it `ready`. The goods are still on hand and still reserved. When the customer receives them, staff marks the order `collected`. This releases the reservation and records a physical stock reduction at the same event time. Central receives that collection in its overnight import. The collection is not entered again as a till sale.

**Business activity C: the order is cancelled before collection.**

If staff cannot find an unreserved bag, staff contacts the customer. In Case 1, Sarah agrees to cancel. Staff changes the order to `cancelled`, records the reason as insufficient stock, and arranges the refund. The online system releases Sarah's reservation immediately. Physical on-hand stock does not increase because no goods left the store. Any goods already set aside for a cancelled order return to the sellable shelf without changing total on-hand quantity.

Refund settlement is outside the stock prototype. The cancellation and its reason are retained so that stock-related cancellations can be distinguished from changes of mind.

| Candidate records | What one record means | Required information |
| --- | --- | --- |
| `web_order` | One online order and its current state | Order ID, placed time, fulfilment type, selected fulfilment location, current status, last update time |
| `web_order_line` | One product line in that order | Order ID, line ID, SKU, quantity |
| `order_status_history` | One recorded status change | Event ID, order ID, previous/new status, event time, source recording time, reason where relevant |
| `web_stock_copy` | One copied product/location balance in a refresh | Copy ID, SKU, location code, copied on-hand quantity, source snapshot ID/cutoff, copy time |

Reservations can be derived from order lines whose orders are `awaiting_pick` or `ready`. A separate reservation table is not necessary unless the later design demonstrates a need for it. The initial prototype excludes partial collection/cancellation, so each line follows its order's status.

**Why this source is needed:** it identifies active commitments, completed collections, cancellation history, and the stock information the website was using.

### 4.3 Source 3: central stock database

**Business activity A: receiving a supplier delivery at the DC.**

A supplier delivers 20 bags. DC staff checks the delivery and confirms the quantity actually received in the stock application. This creates a receipt movement containing the product, receiving location, quantity, receipt time, and supplier/delivery reference. The goods are physically at the DC from receipt time; the central current quantity includes them after the next hourly processing run. A purchase order or an expected delivery alone does not add on-hand stock. Supplier records are limited to the references required to explain receipts.

**Business activity B: transferring products from the DC to a store.**

A stock controller creates a transfer for 10 bags from the DC to Parramatta. Creating the transfer does not itself move stock. DC staff confirms dispatch, creating a reduction at the DC and marking the transfer in transit. Parramatta staff later counts the arriving goods and confirms receipt, creating an increase at Parramatta.

| Step | Physical DC stock | In transit | Physical Parramatta stock | Data created |
| --- | ---: | ---: | ---: | --- |
| Before this separate example | 40 | 0 | 5 | Opening balances |
| 10 bags dispatched from DC | 30 | 10 | 5 | Transfer dispatch event; DC movement of -10 |
| The same 10 bags received at Parramatta | 30 | 0 | 15 | Transfer receipt event; store movement of +10 |

The website's copied store quantity does not increase at either action; it awaits its next stock refresh. Staff-confirmed dispatch and receipt are separate events, linked by one transfer ID. This example uses complete delivery of the expected quantity. Partial deliveries and transfer discrepancies are outside the initial prototype.

**Business activity C: correcting a recorded stock count.**

An authorised staff member confirms a count difference and records a signed adjustment with a reason and time. For example, a confirmed reduction of two units produces a movement of -2. The prototype can process a recorded adjustment; it does not discover unrecorded theft, damage, or counting errors by itself. Damaged units are removed from the sellable stock tracked here through an adjustment; there is no separate unavailable-stock pool in the initial model.

**System activity D: importing transactions from the other databases.**

At 1 am, a scheduled process reads completed store sales and online collection/shipment events before midnight that have not already been applied. It creates central movements with the original source event/line references and event times. Its processing time is recorded separately. This step is automatic, not a staff member entering the sale again.

An uncollected C&C order remains a reservation in the online source. It is not an outgoing physical movement. A cancellation before collection also creates no physical movement. The import must distinguish order acceptance from actual collection/shipment.

The process produces a fixed snapshot of stock as at midnight from all relevant events before that cutoff. Locally recorded movements already reflected in central quantities are not added a second time. Later movements can change central's current records, but do not rewrite this historical snapshot. The website copies that snapshot at 5 am.

| Candidate records | What one record means | Required information |
| --- | --- | --- |
| `product` and `product_barcode` | A product and the barcode(s) identifying it | SKU, name, brand, category, pack size; barcode-to-SKU link |
| `location` | One store or the DC | Location code, name, location type, suburb |
| `stock_transfer` and `stock_transfer_line` | One transfer and its product lines | Transfer ID, origin, destination, status; line ID, SKU, quantity, dispatch and receipt times |
| `stock_movement` | One signed physical quantity change at one location | Movement ID, SKU, location, type, signed quantity, event/recording times, origin event reference, transfer or delivery reference when relevant |
| `stock_on_hand` | Central's current recorded quantity for one product/location | SKU, location, recorded quantity; processing information showing which sales and movements have been applied |
| `stock_snapshot` | A fixed product/location balance at a defined cutoff | Snapshot ID, SKU, location, quantity, cutoff time, snapshot creation time |
| Import/application records | Which source events have already affected central stock | Source, event/line ID, central processing time |

The receipt reference and receipt movement are sufficient for the initial case; a full purchasing system is not required. Snapshot and current-balance tables serve different purposes within the same source database, not two additional sources.

**Why this source is needed:** sales and orders alone cannot explain how much stock existed initially, where it was held, or how deliveries, transfers, and adjustments changed it.

### 4.4 How the sources relate

```text
Staff completes till sale ----------------------> store sales database
Customer places order / staff updates order ----> online orders database
Staff confirms receipt / transfer / adjustment -> central stock database

Store sales database   -- 1 am: prior-day sales -------------> central stock database
Online orders database -- 1 am: prior-day collections -------> central stock database
Central stock database -- 5 am: copy of midnight snapshot ---> online orders database
```

The online source creates its own orders and reservations during the day. The central source creates its own receipts and transfers. Each also holds records copied or derived from another source at specified times. Their responsibilities explain why information exists but is not consistently reflected across the business.

## 5. Stock definitions and calculation rules

### 5.1 On hand, reserved, available, and shortfall

| Term | Meaning in this project |
| --- | --- |
| Actual on hand | Physical sellable units at the location, including units behind the collection counter. In synthetic cases, this is the known reference quantity. |
| Recorded on hand | A quantity stored by a system. It can be outdated. |
| Calculated on hand | Opening snapshot plus subsequent recorded physical movements included in the calculation. It matches the reference quantity only when the required events are present and correct. |
| Reserved | Quantity committed to accepted orders still awaiting collection/shipment. It includes commitments not yet physically picked. |
| Available | Units that can still be promised to a new order, with a minimum of zero. |
| Shortfall | How many committed units exceed calculated on-hand stock. It does not mean physical stock is negative. |

For one product and location at a specified observation time:

```text
Calculated on hand = opening snapshot quantity
                   + receipts and other stock increases since its cutoff
                   - sales, collections, dispatches, and other stock decreases since its cutoff

Net stock after commitments = calculated on hand - active reserved quantity
Available                   = max(net stock after commitments, 0)
Shortfall                   = max(-net stock after commitments, 0)
```

Only events from the opening cutoff up to the observation time are included. Reservations are reconstructed from order history at that same time. An event at midnight belongs after the midnight opening balance, not on both sides of the cutoff.

A reservation is a promise, not proof that a physical unit exists. When Sarah's order is wrongly accepted, two orders can be committed against one remaining bag. Report this as **one on hand, two reserved, zero available, and a shortfall of one**.

### 5.2 Avoid counting the same event twice

A till sale may appear first in the store sales source and later as an imported movement in central stock. These are two records of one event. Preserve the source and event/line ID so the integration applies its quantity once. Do not count both a transfer line and its dispatch movement as separate stock reductions.

When the opening snapshot advances to the next midnight, events already included in it must no longer be applied as later changes. Re-running an import must not subtract the same sale again.

Collection changes two things together in the calculation: on-hand stock decreases and the corresponding reservation ends. Cancellation before collection only ends the reservation. Creating or releasing a reservation must not itself create a physical stock movement.

### 5.3 How the existing website calculates its quantity

The website has its own outdated calculation:

```text
Website net quantity = copied midnight on-hand balance
                     - online collections/shipments since that snapshot's cutoff
                     - current active online reservations

Website available = max(website net quantity, 0)
```

The existing website misses in-store sales and central receipts/transfers/adjustments after the copied cutoff. It does know its own order activity. Consequently:

- Accepting an order reduces its calculated availability.
- Cancelling before collection releases the reservation and increases its calculated availability.
- Collection releases a reservation but also reduces on hand, so it does not make the collected unit available again.
- At 5 am, the website replaces its opening balance and recalculates. It still subtracts outstanding reservations, including orders placed on earlier days. It also applies online collections after the new snapshot's cutoff, including any between midnight and 5 am.

This rule avoids losing overnight reservations or deducting yesterday's fulfilled orders again after they enter the new balance.

### 5.4 Product and location matching

| Identifier | Store sales source | Online orders source | Central stock source |
| --- | --- | --- | --- |
| Product | Scanned barcode | SKU | SKU and its barcode list |
| Location | Store code, e.g. `0123` | Pickup code, e.g. `store-parramatta` | Location code, e.g. `STR-PAR` |

These example codes all refer to the same Parramatta location. Preserve codes as text where leading zeros matter.

Use the existing barcode-to-SKU list and a documented location-code mapping to combine matching records. If a code cannot be matched, flag it for correction rather than assigning it to an arbitrary product or store. Keep the original source identifiers alongside the shared identifiers.

This is the useful part of the earlier master-data proposal: consistent product and location identification. Customer matching, a customer cross-reference table, and a full MDM platform are not needed. Matching identifies which stock records belong together; the extraction and processing schedule determines how current those records are.

### 5.5 Current records and event history

An order's current status can change. Its history records each change without erasing the earlier event.

| Time | Current order state after the action | History event added |
| --- | --- | --- |
| 3 pm | Awaiting pick | Order placed |
| 3:45 pm | Cancelled | Order cancelled because of insufficient stock |

The cancelled order remains identifiable and its lines remain available for reporting. The history preserves both events. For this prototype, corrections to recorded history are represented by additional correction/reversal events rather than silently overwriting the original event.

Do not describe all transaction data as “never changed”. Current transaction records can be updated; the preserved event history explains those changes. Stock snapshots also retain their original cutoff and creation time.

## 6. Cases showing the existing problem

### Case 1: the remaining bag is already promised to another customer

Product: Royal Canin dog food 3 kg. Location: Parramatta store. Opening physical and recorded stock: five bags.

Customer A reserves one bag at 9:30 am and staff sets it aside. Four other bags are sold at tills by 2 pm. Sarah places an order at 3 pm. Staff finds the shortage at 3:30 pm, and Sarah agrees to cancel at 3:45 pm. Customer A does not collect before the next 5 am refresh. There are no other stock movements in this case.

The website column below is its internal calculated availability. Customers see the corresponding “In stock” or “Out of stock” message.

| Time and event | Central recorded on hand | Website available | Actual on hand | Active reserved | Actual available | Shortfall |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Day 1, 1 am: central produces the midnight snapshot | 5 | Previous copy not used in this case | 5 | 0 | 5 | 0 |
| 5 am: website copies the snapshot | 5 | 5 | 5 | 0 | 5 | 0 |
| 9:30 am: A orders one bag; staff sets it aside | 5 | 4 | 5 | 1 | 4 | 0 |
| By 2 pm: four bags sold at tills | 5 | 4 | 1 | 1 | 0 | 0 |
| 3 pm: Sarah sees “Parramatta - In stock”; order accepted | 5 | 3 | 1 | 2 | 0 | 1 |
| 3:30 pm: staff finds only A's set-aside bag | 5 | 3 | 1 | 2 | 0 | 1 |
| 3:45 pm: Sarah cancels; her reservation is released | 5 | 4 | 1 | 1 | 0 | 0 |
| Day 2, 1 am: central imports the four till sales | **1** | **4** | 1 | 1 | 0 | 0 |
| Day 2, 5 am: website copies one on hand, then subtracts A's reservation | 1 | **0** | 1 | 1 | 0 | 0 |

Before Sarah's order, the store sales source knows four bags were sold, the online source knows one is reserved, and central's balance still shows five. Combining the relevant records gives zero available.

At 1 am on Day 2, **only central has processed the store sales**. The website still calculates four because Sarah's cancellation released her reservation. It reaches zero at its 5 am refresh. The bag behind the counter is on hand, but not available to Sarah.

### Case 2: the last bag sells in store before an evening online order

This is a separate example with one opening bag and no earlier reservation. Use it when a short introductory example is needed.

| Time and event | Website available | Actual on hand | Active reserved | Actual available | Shortfall |
| --- | ---: | ---: | ---: | ---: | ---: |
| 5 am: website copies one bag | 1 | 1 | 0 | 1 | 0 |
| 2 pm: a walk-in customer buys it at a till | 1 | 0 | 0 | 0 | 0 |
| 6 pm: an online C&C order is accepted | 0 | 0 | 1 | 0 | 1 |
| Next 1 am: central imports the till sale | 0 | 0 | 1 | 0 | 1 |
| Next 5 am: website refreshes to zero on hand; the unfilled commitment remains | 0 | 0 | 1 | 0 | 1 |
| Next 9 am: staff cannot pick it and cancels the order | 0 | 0 | 0 | 0 | 0 |

The website's zero after accepting the order does not undo the earlier acceptance. The accepted order still needs to be fulfilled or cancelled. A later refresh alone does not resolve it.

## 7. What the prototype will demonstrate

### 7.1 Objective and boundary

> The prototype combines store sales, online orders, and central stock records to calculate stock availability for each product at each location. It compares this result with the website's recorded availability, identifies C&C orders at risk of not being fulfilled, and demonstrates how updated availability changes a simulated online stock check.

The data warehouse stores integrated records, supports calculations, and provides historical reports. A separate demonstration query or small application step uses the calculated availability to answer whether a proposed order has enough stock. The warehouse does not itself operate the live checkout or control real reservations.

The old “Case 3” is replaced by this expected-result demonstration. There is no fixed 15-minute target. The prototype will show when source events were recorded, when they were incorporated, and the resulting stock answer. A production refresh interval would require a separately justified performance and business decision.

### 7.2 Proposed data flow

```text
Three source databases
        |
        v
Extract source records and preserve their IDs and timestamps
        |
        v
Validate data, match products/locations, and apply each event once
        |
        v
Integrated warehouse: stock movements, orders, snapshots, and shared dimensions
        |
        +--> Three reports/dashboard views
        |
        +--> Calculated availability -> simulated online stock check
```

The prototype reads recent store sales from their source; it does not wait for those sales to enter central's overnight batch. This is how the integrated calculation can improve on the website's old copy.

Relational tables hold the source records and matching relationships. A dimensional warehouse supports reporting by product, location, and time. The final fact-table detail, keys, and extraction method belong in the later solution design.

### 7.3 Demonstration using Case 1

Use separate baseline and improved runs of the same scenario, rather than combining contradictory outcomes in one history.

| Step | Baseline behaviour | Improved demonstration |
| --- | --- | --- |
| Load five opening bags, A's reservation, and four subsequent till sales | Website still calculates four available | Integrated calculation gives one on hand minus one reserved = zero available |
| Check Sarah's proposed one-bag order at 3 pm | Outdated website answer permits acceptance | Simulated check reports insufficient stock at Parramatta |
| Review the historical baseline run after acceptance | Two commitments compete for one bag | Shortfall report identifies one unit missing; acceptance order gives A priority and identifies Sarah's order as at risk |
| Process Sarah's cancellation and advance the baseline run to the next morning | Website temporarily returns to four, then reaches zero after the 5 am refresh | History and snapshots explain each quantity change |

The prototype demonstrates correct results for the recorded scenarios. It does not claim to prevent every simultaneous purchase in a live system. Production order acceptance would also need a transaction that checks and reserves stock safely when customers order at the same time.

### 7.4 Three required reporting outputs

| Output | Question answered | Minimum contents |
| --- | --- | --- |
| Stock availability comparison | Where does website availability differ from the combined calculation? | Product, location, observation time, website quantity, calculated on hand, reserved, available, shortfall, difference |
| C&C orders at risk and stock-related cancellations | Which accepted orders cannot be covered, and which were cancelled for insufficient stock? | Order/line, product, pickup store, status, required quantity, allocated quantity/shortfall, cancellation reason/time |
| Data update delay | How long did events take to reach the integrated result, and how old was the website's stock basis? | Source event/recording time, warehouse load time, observed processing delay; website snapshot cutoff and copy time |

For the initial at-risk report, allocate calculated on-hand quantity to active order lines in acceptance-time order, using order ID to break ties. Start with on hand, before subtracting reservations, so those commitments are not deducted twice. Historical reports must use status history at the observation time, not just today's current order status.

Website snapshot age and event-processing delay are different measures. A copy made at 5 am from a midnight snapshot is already based on a five-hour-old balance. Report missing or unmatched records separately; a timestamp alone does not prove all required events were received.

### 7.5 Checks for the later implementation

The end-to-end demonstration must verify:

- Case 1 produces the quantities in §6, including the cancellation, separate 1 am and 5 am updates, and A's carried-over reservation.
- A completed collection reduces on hand and ends its reservation without making the collected unit available again.
- A supplier receipt increases the receiving location; a DC dispatch does not increase store stock until confirmed receipt.
- Imported sales are not counted again as new central events, and re-running a load does not duplicate their effects.
- Advancing the opening snapshot excludes events already inside that snapshot from later adjustments.
- Barcode/location mappings join the correct records, and unmatched records are visible for correction.
- The simulated stock check and all three reporting outputs use the same definitions.

These are planned checks, not claims that the current code implements or passes them.

### 7.6 Why the design differs from Assignment 1

| Assignment 1 direction | Assignment 2 decision | Reason |
| --- | --- | --- |
| Five enterprise data problems and several use cases | One C&C stock-availability problem with several cases | Gives the business problem a clear boundary and an observable result |
| MDM plus graph for customer, pet, and account relationships | Product and location matching only; no graph database | Customer/pet matching is out of scope. This calculation uses identifiers, dated movements, and quantity totals rather than indirect relationship traversal |
| Data fabric proposed for inventory synchronisation | Explicit source extraction, matching, stock calculation, and a simulated check | The implementation must explain exactly how newer records reach the result; a technology label alone does not establish that behaviour |
| Reporting platform deferred | Integrated warehouse and three reporting outputs included | Historical analysis and reporting are required parts of Assignment 2 |
| POS, digital, and grooming used ambiguously | Three source databases with named business actions and records | A till, a sales channel, and a service do not describe the data to extract clearly |
| Broad customer journey including grooming and split fulfilment | One pickup store per C&C order; no grooming or split fulfilment | Keeps the prototype focused and its stock rules explainable |

Graph remains a valid model for workloads that repeatedly follow chains of relationships. It is omitted because those requirements are absent here. Product/location matching is a supporting integration step, not a claim to have implemented a full MDM platform.

The later design must include the architecture, conceptual and logical models, rationale and trade-offs, at least three source schemas, at least one integrated warehouse, commented executable SQL with synthetic data, the reporting outputs, and a recorded end-to-end demonstration in the provided Lab Environment. This guide sets the business rules; it does not claim that the existing code or infrastructure already meets them.

## 8. Data and terminology guide

### 8.1 Kinds of records

All prototype data is structured and stored in relational tables.

| Kind | PetHaven examples | How it changes |
| --- | --- | --- |
| Master data | Products, barcode relationships, stores, DC | Changes when the business introduces or maintains products and locations |
| Reference data | Allowed status, movement, and fulfilment-type codes | Changes when business rules change |
| Current transaction records | Order header/lines, current transfer status | Updated as work proceeds |
| Event history | Completed sale lines, status changes, receipts, dispatches, adjustments | New events are added; corrections retain the earlier history |
| Stock balances and snapshots | Current recorded on hand; fixed midnight balances and website copies | Current balances change; historical snapshots retain their cutoff |
| Integration records | Location mappings, source event references, processing times | Maintained as sources are matched and records are processed |

Identifiers and codes must retain their original formatting. Quantities use integers; monetary amounts use decimal types. Each event needs its occurrence time and source recording time. Integration adds the time it was loaded or applied. A snapshot needs both its effective cutoff and its creation/copy time.

For scale discussion, approximately three lines per in-store sale would produce about 18,000 sale lines per day. That line count is a modelling assumption. A full 10,000-product by 31-location snapshot would contain about 310,000 rows if every combination is represented. The prototype uses a small synthetic sample covering the cases and several daily processing cycles.

Customer names, contact details, payment-card details, and pet profiles are excluded. Synthetic order IDs are sufficient. The prototype contains internal business records and no real customer data; this does not establish the privacy classification of every equivalent production record.

### 8.2 Word list

| Term | Meaning here |
| --- | --- |
| POS till | Connected machine and software used to complete an in-store sale |
| Store sales database | Source holding the completed till sales |
| Online store | Website/app through which customers place online orders |
| Central stock system | Application and database managing stock records across stores and the DC |
| Stock / inventory | Products held for sale; the words refer to the same business subject |
| Stock snapshot / stock copy | Recorded quantities with a defined effective time; a copied record also has a copy time |
| SKU | PetHaven's product code |
| Barcode | Code scanned from a product pack and mapped to its SKU |
| DC | Physical distribution centre |
| Data warehouse | Integrated database for calculations, reporting, and historical analysis |
| Data source | Origin of the records extracted for the prototype; here, one of the three operational databases |
| Schema | Either a named group of database tables, or their design, depending on context |
| Business key | A business identifier such as SKU or store code |
| Master data | Shared descriptions and identifiers for products and locations |
| Cross-reference / mapping | A recorded link between identifiers for the same product or location |
| Batch processing | Processing a group of records on a schedule or in a defined run |
| ETL | Extract, transform, and load data into the integrated store; the later design will specify where transformations run |
| Overselling | Accepting commitments for more units than can be supplied |

Use a technical term when it explains the design, and define it when first needed. Describe the actual data, action, and timing rather than relying on broad claims such as “seamless integration”.

## Sources

The external sources below support the retail behaviour and terminology used in the case. They do not verify PetHaven's assumed store count, volumes, overnight schedule, or proposed architecture.

- [Petbarn: How Click & Collect works](https://petbarn.zendesk.com/hc/en-au/articles/19795183083161-How-Click-Collect-works). Supports selecting a store, checking stock, and waiting for collection confirmation. Petbarn states that all cart items must be available for C&C and in stock at the chosen store to complete the order.
- [Petstock: Why can't I Click & Collect from my local store?](https://support.petstock.com.au/hc/en-us/articles/360033252612-Why-can-t-I-Click-Collect-from-my-local-store). Supports location-specific availability and offering an alternative store or home delivery.
- [David Jones: Click & Collect](https://www.davidjones.com/click-and-collect). Supports online ordering, store selection, and collection confirmation. David Jones also describes inter-store transfers; PetHaven's initial C&C model is deliberately limited to stock already at the selected store.
- [Woolworths: Terms and Conditions, sections 3.11-3.12](https://www.woolworths.com.au/shop/services/terms-and-conditions). Describes unavailable ordered products, substitutions, and refunds. This supports the possible customer outcome, not a claim that Woolworths uses PetHaven's update schedule.
- [Shopify: Understanding inventory states](https://help.shopify.com/en/manual/products/inventory/fundamentals/inventory-states). Supports distinguishing on-hand, committed, available, and unavailable quantities. PetHaven's initial model tracks sellable stock and commitments; recorded adjustments remove unusable units rather than maintaining a separate unavailable-stock pool.
