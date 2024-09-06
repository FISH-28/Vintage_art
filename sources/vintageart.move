#[allow(unused_use, unused_variable, unused_const, lint(self_transfer), unused_field)]
module vintageart::marketplace {
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::clock::{Self, Clock};
    use sui::object::{Self, ID, UID};
    use sui::sui::SUI;
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use std::option::{Self, Option};
    use std::vector::{Self, contains};

    const AUCTION_ENDED: u64 = 0;
    const AUCTION_ACTIVE: u64 = 1;
    const BID_TOO_LOW: u64 = 2;
    const NO_BIDS_RECEIVED: u64 = 3;
    const NOT_ITEM_OWNER: u64 = 4;
    const INCORRECT_AUCTION: u64 = 5;
    const WINNER_CANNOT_GET_REFUND: u64 = 6;
    const INVALID_2FA_TOKEN: u64 = 7;  // New error code for invalid 2FA token

    // Owned object representing a vintage item
    struct VintageItem has key, store {
        id: UID,
        title: vector<u8>,
        description: vector<u8>,
        minimum_bid: u64,
        final_price: u64,
    }

    // Shared object to manage the auction
    struct Auction has key {
        id: UID,
        item_id: ID,
        bid_pool: Balance<SUI>,
        reserve_price: u64,
        top_bid: u64,
        top_bidder: Option<address>,
        status: u8, // 0 - open, 1 - closed
        auction_end_time: u64,
        seller: address, // Track seller for 2FA
        valid_2fa_tokens: vector<u64>, // List of valid 2FA tokens
    }

    // Owned object for bidders to claim refunds
    struct BidReceipt has key, store {
        id: UID,
        auction_id: ID,
        amount: u64,
    }

    // Function to create a vintage item and start an auction
    public fun create_vintage_item(title: vector<u8>, description: vector<u8>, minimum_bid: u64, clock: &Clock, ctx: &mut TxContext): VintageItem {
        let item = VintageItem {
            id: object::new(ctx),
            title,
            description,
            minimum_bid,
            final_price: 0,
        };

        let item_id = object::uid_to_inner(&item.id);

        // Set auction end time (e.g., 20 seconds from current time)
        let current_time = clock::timestamp_ms(clock);
        let end_time = current_time + 20_000; // 20 seconds in milliseconds

        let seller = tx_context::sender(ctx);
        let auction = Auction {
            id: object::new(ctx),
            item_id,
            bid_pool: balance::zero(),
            reserve_price: minimum_bid,
            top_bid: minimum_bid,
            top_bidder: option::none(),
            status: 0,
            auction_end_time: end_time,
            seller,
            valid_2fa_tokens: vector::empty(), // Initialize with no valid tokens
        };

        transfer::share_object(auction);

        item
    }

    // Function to add a valid 2FA token to the auction
    public fun add_2fa_token(auction: &mut Auction, token: u64, ctx: &mut TxContext) {
        assert!(auction.seller == tx_context::sender(ctx), NOT_ITEM_OWNER);
        vector::push_back(&mut auction.valid_2fa_tokens, token);
    }

    // Function to validate the 2FA token
    fun validate_2fa_token(auction: &Auction, token: u64) {
        assert!(contains(&auction.valid_2fa_tokens, &token), INVALID_2FA_TOKEN);
    }

    // Function to place a bid in the auction
    public fun place_bid(auction: &mut Auction, bid_amount: Coin<SUI>, clock: &Clock, ctx: &mut TxContext): BidReceipt {
        let current_time = clock::timestamp_ms(clock);
        assert!(auction.auction_end_time > current_time, AUCTION_ENDED);
        assert!(auction.status == 0, AUCTION_ENDED);

        let bid_value = coin::value(&bid_amount);
        assert!(bid_value > auction.top_bid, BID_TOO_LOW);

        let bid_balance = coin::into_balance(bid_amount);
        balance::join(&mut auction.bid_pool, bid_balance);

        auction.top_bid = bid_value;
        auction.top_bidder = option::some(tx_context::sender(ctx));

        let auction_id = object::uid_to_inner(&auction.id);
        let receipt = BidReceipt {
            id: object::new(ctx),
            auction_id,
            amount: bid_value,
        };

        receipt
    }

    // Function to finalize the auction and transfer the item to the highest bidder
    public fun finalize_auction(item: VintageItem, auction: &mut Auction, token: u64, clock: &Clock, ctx: &mut TxContext): Coin<SUI> {
        assert!(auction.seller == tx_context::sender(ctx), NOT_ITEM_OWNER);

        // Validate the 2FA token
        validate_2fa_token(auction, token);

        assert!(&auction.item_id == object::uid_as_inner(&item.id), NOT_ITEM_OWNER);

        let current_time = clock::timestamp_ms(clock);
        assert!(auction.auction_end_time <= current_time, AUCTION_ACTIVE);
        assert!(auction.top_bid >= auction.reserve_price, NO_BIDS_RECEIVED);

        let final_price = coin::take(&mut auction.bid_pool, auction.top_bid, ctx);

        item.final_price = auction.top_bid;

        let highest_bidder = option::extract<address>(&mut auction.top_bidder);
        transfer::public_transfer(item, highest_bidder);

        auction.status = 1;

        final_price
    }

    // Function to cancel an auction (requires 2FA)
    public fun cancel_auction(auction: &mut Auction, token: u64, ctx: &mut TxContext) {
        assert!(auction.seller == tx_context::sender(ctx), NOT_ITEM_OWNER);

        // Validate the 2FA token
        validate_2fa_token(auction, token);

        assert!(option::is_none(&auction.top_bidder), AUCTION_ACTIVE);

        auction.status = 1;
       //object::delete(object::UID_to_inner(&auction.id))
    }

    // Function for bidders to claim refunds if they didn't win the auction
    public fun claim_refund(auction: &mut Auction, receipt: BidReceipt, ctx: &mut TxContext): Coin<SUI> {
        let BidReceipt { id, amount, auction_id } = receipt;
        assert!(&auction_id == object::uid_as_inner(&auction.id), INCORRECT_AUCTION);
        assert!(!option::contains(&auction.top_bidder, &tx_context::sender(ctx)), WINNER_CANNOT_GET_REFUND);
        assert!(auction.status == 1, AUCTION_ACTIVE);

        object::delete(id); // Explicitly delete the BidReceipt object

        let refund = coin::take(&mut auction.bid_pool, amount, ctx);
        refund
    }

    #[test_only] use sui::test_scenario as ts;
    #[test_only] const SELLER_ADDR: address = @0x1;
    #[test_only] const BIDDER1_ADDR: address = @0xA;
    #[test_only] const BIDDER2_ADDR: address = @0xB;

    #[test]
    fun test_vintage_auction_with_2fa() {
        let ts = ts::begin(@0x0);
        let clock = clock::create_for_testing(ts::ctx(&mut ts));

        {   
            ts::next_tx(&mut ts, SELLER_ADDR);

            let title = b"Antique Pocket Watch";
            let description = b"1988 Old Man Edition Watch";
            let minimum_bid: u64 = 5;

            let item = create_vintage_item(title, description, minimum_bid, &clock, ts::ctx(&mut ts));
            transfer::public_transfer(item, SELLER_ADDR);
        };

        {
            ts::next_tx(&mut ts, SELLER_ADDR);

            let auction = ts::take_shared(&ts);
            add_2fa_token(&mut auction, 123456, ts::ctx(&mut ts)); // Adding a valid 2FA token
            ts::return_shared(auction);
        };

        {
            ts::next_tx(&mut ts, BIDDER1_ADDR);

            let auction = ts::take_shared(&ts);
            let bid_coin = coin::mint_for_testing<SUI>(8, ts::ctx(&mut ts));
            let receipt = place_bid(&mut auction, bid_coin, &clock, ts::ctx(&mut ts));
            transfer::public_transfer(receipt, BIDDER1_ADDR);

            ts::return_shared(auction);
        };

        {
            ts::next_tx(&mut ts, BIDDER2_ADDR);

            let auction = ts::take_shared(&ts);
            let bid_coin = coin::mint_for_testing<SUI>(14, ts::ctx(&mut ts));
            let receipt = place_bid(&mut auction, bid_coin, &clock, ts::ctx(&mut ts));
            transfer::public_transfer(receipt, BIDDER2_ADDR);

            ts::return_shared(auction);
        };

        {
            ts::next_tx(&mut ts, SELLER_ADDR);

            clock::increment_for_testing(&mut clock, 21_000); // Advance time by 21 seconds
            let auction: Auction = ts::take_shared(&ts);
            let item: VintageItem = ts::take_from_sender(&ts);
            let final_price = finalize_auction(item, &mut auction, 123456, &clock, ts::ctx(&mut ts)); // Provide the 2FA token
            transfer::public_transfer(final_price, SELLER_ADDR);

            ts::return_shared(auction);
        };

        {
            ts::next_tx(&mut ts, BIDDER1_ADDR);

            let auction: Auction = ts::take_shared(&ts);
            let receipt: BidReceipt = ts::take_from_sender(&ts);
            let refund = claim_refund(&mut auction, receipt, ts::ctx(&mut ts));
            transfer::public_transfer(refund, BIDDER1_ADDR);

            ts::return_shared(auction);
        };

        clock::destroy_for_testing(clock);
        ts::end(ts);
    }
}