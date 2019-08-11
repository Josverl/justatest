// test that the serial can be loaded
const expect  = require('chai').expect;
const assert  = require('chai').assert;
var should = require('chai').should()

describe("indextest",function(){

    it('can load index', function(done) {
        assert.doesNotThrow( function(){
            const port = require('../index.js');
            done();
        })
    });


});
