require 'rails_helper'

feature 'User edit' do
  let(:user) { create(:user, :signed_up) }

  context 'editing email' do
    let(:new_email) { 'new_email@test.com' }

    before do
      sign_in_and_2fa_user(user)
      visit manage_email_path
    end

    scenario 'user is not able to submit form without entering an email' do
      fill_in 'Email', with: ''
      click_button 'Update'

      expect(page).to have_current_path manage_email_path
    end

    scenario 'user receives confirmation message at new address' do
      fill_in 'Email', with: new_email
      click_button 'Update'

      open_last_email
      click_email_link_matching(/confirmation_token/)

      expect(page).to have_content(new_email)
    end
  end

  context 'editing 2FA phone number' do
    before do
      sign_in_and_2fa_user(user)
      visit manage_phone_path
    end

    scenario 'confirm change submit button is disabled without phone number', js: true do
      phone_input = page.find('#user_phone_form_phone')
      phone_input.send_keys(*([:backspace] * phone_input.value.length))

      expect(page).to have_button(t('forms.buttons.submit.confirm_change'), disabled: true)
    end

    scenario 'user is able to submit with a Puerto Rico phone number as a US number', js: true do
      fill_in 'user_phone_form_phone', with: '787 555-1234'

      expect(page.find('#user_phone_form_international_code', visible: false).value).to eq 'PR'
      expect(page).to have_button(t('forms.buttons.submit.confirm_change'), disabled: false)
    end

    scenario 'confirms with selected OTP delivery method and updates user delivery preference' do
      allow(SmsOtpSenderJob).to receive(:perform_later)
      allow(VoiceOtpSenderJob).to receive(:perform_now)

      fill_in 'user_phone_form_phone', with: '703-555-5000'
      choose 'Phone call'

      click_button t('forms.buttons.submit.confirm_change')

      user.reload

      expect(current_path).to eq(login_otp_path(otp_delivery_preference: :voice))
      expect(SmsOtpSenderJob).to_not have_received(:perform_later)
      expect(VoiceOtpSenderJob).to have_received(:perform_now)
      expect(user.otp_delivery_preference).to eq('voice')
    end
  end

  context 'deleting 2FA phone number' do
    before do
      sign_in_and_2fa_user(user)
      visit manage_phone_path
    end

    scenario 'delete not an option if no other mfa configured' do
      expect(MfaPolicy.new(user).multiple_factors_enabled?).to eq false

      expect(page).to_not have_button(t('forms.buttons.delete'))
    end

    context 'with multiple mfa configured' do
      let(:user) { create(:user, :signed_up, :with_piv_or_cac) }

      scenario 'delete is an option that works' do
        expect(MfaPolicy.new(user).multiple_factors_enabled?).to eq true

        expect(page).to have_button(t('forms.phone.buttons.delete'))
        click_button t('forms.phone.buttons.delete')
        expect(page).to have_current_path(account_path)
        expect(MfaPolicy.new(user.reload).multiple_factors_enabled?).to eq false
        expect(page).to have_content t('event_types.phone_removed')
      end
    end
  end

  context "user A accesses create password page with user B's email change token" do
    it "redirects to user A's account page", email: true do
      sign_in_and_2fa_user(user)
      visit manage_email_path
      fill_in 'Email', with: 'user_b_new_email@test.com'
      click_button 'Update'
      confirmation_link = parse_email_for_link(last_email, /confirmation_token/)
      token = confirmation_link.split('confirmation_token=').last
      visit destroy_user_session_path
      user_a = create(:user, :signed_up)
      sign_in_and_2fa_user(user_a)
      visit sign_up_enter_password_path(confirmation_token: token)

      expect(page).to have_current_path(account_path)
      expect(page).to_not have_content user.email_addresses.first.email
    end
  end

  context 'editing password' do
    before do
      sign_in_and_2fa_user(user)
      visit manage_password_path
    end

    scenario 'user sees error message if form is submitted with invalid password' do
      fill_in 'New password', with: 'foo'
      click_button 'Update'

      expect(page).
        to have_content t('errors.messages.too_short.other', count: Devise.password_length.first)
    end
  end
end
