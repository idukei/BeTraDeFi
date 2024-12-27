use anchor_lang::prelude::*;

declare_id!("8P8E86Du9K1uo5CSeU1MkmRbEqDKvfWtwWdGijRZAuzf");

#[program]
pub mod betradefi_solana {
    use super::*;

    pub fn initialize(ctx: Context<Initialize>) -> Result<()> {
        msg!("Greetings from: {:?}", ctx.program_id);
        Ok(())
    }
}

#[derive(Accounts)]
pub struct Initialize {}
