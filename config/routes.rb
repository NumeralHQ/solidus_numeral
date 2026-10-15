# frozen_string_literal: true

Spree::Core::Engine.routes.draw do
  namespace :admin do
    resources :users, only: [] do
      member do
        get :numeral_information
        put :numeral_information
      end
    end
  end
end
