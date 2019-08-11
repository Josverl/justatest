// test that the serial can be loaded
const expect  = require('chai').expect;
const assert  = require('chai').assert;
var should = require('chai').should()

describe('Array', function() {
    describe('#indexOf()', function() {

        it('should return -1 when the value is not present', function() {
            assert.equal([1, 2, 3].indexOf(4), -1);
        });
    });
});


describe("Serialport in NodeJS",function(){
    it('can load the serialport', function(done) {
        assert.doesNotThrow( function(){
            const port = require('serialport');
            done();
        })
    });

    it('can list ports' );

    it('can open a port');

    it('can close the port');
});
