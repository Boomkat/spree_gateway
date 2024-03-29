module Spree
  class Gateway::BraintreeGateway < Gateway
    preference :environment, :string
    preference :merchant_id, :string
    preference :merchant_account_id, :string
    preference :public_key, :string
    preference :private_key, :string
    preference :client_side_encryption_key, :text

    CARD_TYPE_MAPPING = {
      'American Express' => 'american_express',
      'Diners Club' => 'diners_club',
      'Discover' => 'discover',
      'JCB' => 'jcb',
      'Laser' => 'laser',
      'Maestro' => 'maestro',
      'MasterCard' => 'master',
      'Solo' => 'solo',
      'Switch' => 'switch',
      'Visa' => 'visa'
    }

    def provider
      provider_instance = super
      Braintree::Configuration.custom_user_agent = "Spree #{Spree.version}"
      Braintree::Configuration.environment = preferred_environment.to_sym
      Braintree::Configuration.merchant_id = preferred_merchant_id
      Braintree::Configuration.public_key = preferred_public_key
      Braintree::Configuration.private_key = preferred_private_key

      provider_instance
    end

    def provider_class
      ActiveMerchant::Billing::BraintreeBlueGateway
    end

    def authorize(money, creditcard, options = {})
      options = adjust_options_for_braintree(creditcard, options)

      if creditcard.gateway_payment_profile_id.present? && creditcard.created_at > 2.minutes.ago
        options[:payment_method_nonce] = creditcard.gateway_payment_profile_id
      end

      if creditcard.gateway_payment_profile_id.present? && creditcard.created_at < 2.minutes.ago
        options[:payment_method_token] = creditcard.gateway_payment_profile_id
        options[:payment_method_nonce] = creditcard.verification_value
      end

      result = provider.authorize(money, nil, options)

      creditcard.update_attributes(
        gateway_payment_profile_id: result.params['credit_card_token'] || creditcard.payments.first.try(:identifier),
        gateway_customer_profile_id: result.params['customer_vault_id']
      ) if result.success?

      result
    end

    def capture(amount, authorization_code, ignored_options = {})
      provider.capture(amount, authorization_code)
    end

    def create_profile(payment)
      return unless payment.source.gateway_customer_profile_id.nil?

      options = options_for_payment(payment)

      if payment.source.gateway_customer_profile_id.nil? && payment.source.number.present?
        response = provider.store(payment.source, options)

        if response.success?
          payment.source.update!(:gateway_customer_profile_id => response.params['customer_vault_id'])
          cc = response.params['braintree_customer'].fetch('credit_cards',[]).first
          update_card_number(payment.source, cc) if cc
        else
          payment.send(:gateway_error, response.message)
        end
      end
    end

    def update_card_number(source, cc)
      last_4 = cc['last_4']
      source.last_digits = last_4 if last_4
      source.gateway_payment_profile_id = cc['token']
      source.cc_type = CARD_TYPE_MAPPING[cc['card_type']] if cc['card_type']
      source.save!
    end

    def credit(*args)
      if args.size == 4
        # enables ability to refund instead of credit
        args.slice!(1,1)
        credit_without_payment_profiles(*args)
      elsif args.size == 3
        credit_without_payment_profiles(*args)
      else
        raise ArgumentError, "Expected 3 or 4 arguments, received #{args.size}"
      end
    end

    # Braintree now disables credits by default, see https://www.braintreepayments.com/docs/ruby/transactions/credit
    def credit_with_payment_profiles(amount, payment, response_code, option)
      provider.credit(amount, payment)
    end

    def credit_without_payment_profiles(amount, response_code, options)
      provider # braintree provider needs to be called here to properly configure braintree gem.
      transaction = ::Braintree::Transaction.find(response_code)
      if BigDecimal.new(amount.to_s) == (transaction.amount * 100)
        provider.refund(response_code)
      elsif BigDecimal.new(amount.to_s) < (transaction.amount * 100) # support partial refunds
        provider.refund(amount, response_code)
      else
        raise NotImplementedError
      end
    end

    def payment_profiles_supported?
      # NOTE: To adopt 3DSv2 on Transaction#sale instead of payment cards,
      #  the Payment Profiles have to be created AFTER the sale.
      false
    end

    def purchase(money, creditcard, options = {})
      authorize(money, creditcard, options.merge(:submit_for_settlement => true))
    end

    def void(response_code, *ignored_options)
      provider.void(response_code)
    end

    def options
      h = super
      # We need to add merchant_account_id only if present when creating BraintreeBlueGateway
      # Remove it since it is always part of the preferences hash.
      if h[:merchant_account_id].blank?
        h.delete(:merchant_account_id)
      end
      h
    end

    def cancel(response_code)
      provider
      transaction = ::Braintree::Transaction.find(response_code)
      # From: https://www.braintreepayments.com/docs/ruby/transactions/refund
      # "A transaction can be refunded if its status is settled or settling.
      # If the transaction has not yet begun settlement, it should be voided instead of refunded.
      if transaction.status == Braintree::Transaction::Status::SubmittedForSettlement
        provider.void(response_code)
      else
        provider.refund(response_code)
      end
    end

    def client_token(client_token = nil)
      provider.generate_client_token(client_token)
    end

    def noncify(token)
      provider.generate_nonce(token)
    end

    protected

      def adjust_billing_address(creditcard, options)
        if creditcard.gateway_customer_profile_id
          options.delete(:billing_address)
        end

        if payment = creditcard.payments.first
          options[:first_name] = payment.order.bill_address.firstname
          options[:last_name] = payment.order.bill_address.lastname
        end

        options[:store] = true

        # NOTE: Discover cards do not support 3DSv2
        if creditcard.cc_type.downcase.include?('discover')
          options[:three_d_secure] = {
            required: false
          }
        end

        options
      end

      def adjust_options_for_braintree(creditcard, options)
        adjust_billing_address(creditcard, options)
      end

      def options_for_payment(p)
        o = Hash.new
        o[:email] = p.order.email

        if p.order.bill_address
          bill_addr = p.order.bill_address

          o[:first_name] = bill_addr.firstname
          o[:last_name] = bill_addr.lastname

          o[:billing_address] = {
            address1: bill_addr.address1,
            address2: bill_addr.address2,
            company: bill_addr.company,
            city: bill_addr.city,
            state: bill_addr.state ? bill_addr.state.name : bill_addr.state_name,
            country_code_alpha3: bill_addr.country.iso3,
            zip: bill_addr.zipcode
          }

          o[:customer] = {
            first_name: bill_addr.firstname,
            last_name: bill_addr.lastname,
            email: p.order.email,
          }
        end

        o[:options] = {
          :verify_card => "true",
          :store_in_vault => "true"
        }

        o[:verify_card] = "true"
        o[:store] = "true"

        return o
      end

  end
end
