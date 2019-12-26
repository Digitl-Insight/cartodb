var CoreView = require('backbone/core-view');
var checkAndBuildOpts = require('builder/helpers/required-opts');
var template = require('./selected-import-header.tpl');

var REQUIRED_OPTS = [
  'title',
  'name'
];

/**
 *  Selected Import header
 */

module.exports = CoreView.extend({

  events: {
    'click .js-back': '_goToList'
  },

  initialize: function (opts) {
    checkAndBuildOpts(opts, REQUIRED_OPTS, this);
  },

  render: function () {
    this.$el.html(
      template({
        title: this._title,
        name: this._name,
        __ASSETS_PATH__: '__ASSETS_PATH__'
      })
    );
    return this;
  },

  _goToList: function () {
    this.trigger('showImportsSelector', this);
  }
});